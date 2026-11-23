import CoreGraphics
import DisplayBridge
import Foundation

struct Session: Equatable, Sendable {
    var topology: UInt64 = 0
    var audioRoute: UInt64 = 0
}

// Updated immediately by reconfiguration notifications, even while a transfer
// is running. A second check immediately before each hardware write protects
// queued commands for the previous monitor or audio route.
final class SessionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Session()
    private var writeWaiting = false

    func snapshot() -> Session { lock.withLock { current } }
    func resetDisplays() { lock.withLock { current.topology &+= 1 } }
    func resetAudio() { lock.withLock { current.audioRoute &+= 1 } }
    /// A level read can wait, and a change the user just made cannot. A read
    /// that is under way stops at its next request and is started again later.
    func setWriteWaiting(_ waiting: Bool) { lock.withLock { writeWaiting = waiting } }
    var isWriteWaiting: Bool { lock.withLock { writeWaiting } }
    func accepts(_ session: Session, audio: Bool = false) -> Bool {
        lock.withLock { current.topology == session.topology && (!audio || current.audioRoute == session.audioRoute) }
    }
}

struct ControlKey: Hashable, Sendable {
    let id: String
    let feature: Feature
}

struct DisplayWrite: Sendable {
    let key: ControlKey
    let fraction: Double
    let routeIsCurrent: (@Sendable () -> Bool)?

    /// Reads the level back without sending it again.
    var verifyOnly = false
    /// Set once the level has been sent a second time after a failed check.
    var resent = false

    func isCurrent(fence: SessionFence, session: Session) -> Bool {
        guard fence.accepts(session, audio: key.feature.isAudio) else { return false }
        guard let routeIsCurrent else { return true }
        // Core Audio may block in the route query while a dock disconnects.
        return routeIsCurrent() && fence.accepts(session, audio: key.feature.isAudio)
    }
}

enum WriteResult: Sendable {
    case sent
    case confirmed(Double)
    case unconfirmed(Double?)
    case obsolete
}

// All handles and register ranges are confined to this serial queue. Each
// operation can block on I²C without occupying the main actor or a Swift
// cooperative-executor thread.
protocol DisplayIO: Sendable {
    var fence: SessionFence { get }
    func releaseConnections()
    func scan(_ screens: [ScreenDescription], session: Session) async -> [MonitorDisplay]
    /// Nil when a waiting write cut the read short.
    func refresh(ids: [String], session: Session) async -> [MonitorDisplay]?
    func write(_ request: DisplayWrite, session: Session) async -> WriteResult
}

/// What is known about each monitor's mute register: 0 when it holds a write,
/// otherwise the value it keeps reporting whatever is written.
struct MuteMemory: Sendable {
    var load: @Sendable () -> [String: Int] = { [:] }
    var save: @Sendable ([String: Int]) -> Void = { _ in }

    static let defaults = MuteMemory(
        load: { UserDefaults.standard.dictionary(forKey: "muteRegisters") as? [String: Int] ?? [:] },
        save: { UserDefaults.standard.set($0, forKey: "muteRegisters") })
}

final class DisplayWorker: DisplayIO, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DisplayHardware.DDC", qos: .userInitiated)
    private var endpoints: [String: Endpoint] = [:]
    let fence = SessionFence()
    private let discover: @Sendable ([ScreenDescription]) -> [Endpoint]
    private let isOnline: @Sendable (CGDirectDisplayID) -> Bool
    private let memory: MuteMemory
    private lazy var muteRegisters = memory.load()
    /// The volume to return to when a monitor muted through its volume is unmuted.
    private var restoreLevels: [String: UInt16] = [:]

    init(discover: @escaping @Sendable ([ScreenDescription]) -> [Endpoint] = Discovery.endpoints,
         isOnline: @escaping @Sendable (CGDirectDisplayID) -> Bool = { CGDisplayIsOnline($0) != 0 },
         memory: MuteMemory = MuteMemory()) {
        self.discover = discover
        self.isOnline = isOnline
        self.memory = memory
    }

    private func remember(mute value: Int?, for endpoint: Endpoint) {
        let id = endpoint.display.id
        guard muteRegisters[id] != value else { return }
        muteRegisters[id] = value
        // An identifier that lasts only until the displays change is not worth keeping.
        let known = endpoints.values.filter { !$0.display.canRememberPairing }.map(\.display.id)
        memory.save(muteRegisters.filter { !known.contains($0.key) })
    }

    /// Some monitors answer a mute read with a fixed value and ignore mute
    /// writes (a Dell S3425DW always says "muted"). Reading alone cannot tell
    /// that from a real mute, so ask a monitor that says it is muted to unmute,
    /// once, and put the mute back if it did.
    private func probeMute(_ id: String, session: Session) {
        guard var endpoint = endpoints[id], let channel = endpoint.channel, muteRegisters[id] == nil,
              endpoint.readings[.mute]?.current == 1, endpoint.readings[.volume] != nil else { return }
        let allowed = { self.fence.accepts(session) }
        func send(_ value: UInt16) {
            for _ in 0..<2 {
                usleep(10000)
                guard allowed() else { return }
                _ = channel.write(.mute, value: value)
            }
        }
        send(2)
        var observed: DDCValue?
        for pause: useconds_t in [50000, 250000] {
            usleep(pause)
            observed = read(.mute, on: endpoint, allowed: allowed)
            if observed?.current == 2 { break }
        }
        guard allowed(), let observed else { return }
        if observed.current == 2 {
            send(1)
            remember(mute: 0, for: endpoint)
        } else {
            remember(mute: 1, for: endpoint)
            endpoint.mutesByVolume = true
            endpoints[id] = endpoint
        }
    }

    private func restoreLevel(_ id: String, _ volume: DDCValue) -> UInt16 {
        restoreLevels[id] ?? max(1, volume.maximum / 10)
    }

    private func snapshot(_ endpoint: Endpoint) -> MonitorDisplay {
        var display = endpoint.snapshot
        if display.mutesByVolume, let volume = endpoint.readings[.volume] {
            display.restoreVolume = Double(restoreLevel(display.id, volume)) / Double(volume.maximum)
        }
        return display
    }

    /// Mute for a monitor whose own mute does nothing: volume zero, and the
    /// earlier level again to unmute.
    private func writeMuteByVolume(_ request: DisplayWrite, endpoint: Endpoint, allowed: () -> Bool) -> WriteResult {
        var endpoint = endpoint
        let id = request.key.id
        let mute = request.fraction != 0
        guard let channel = endpoint.channel, let volume = endpoint.readings[.volume] else { return .unconfirmed(nil) }
        var observed: DDCValue? = volume
        if !request.verifyOnly && (volume.current == 0) != mute {
            if mute { restoreLevels[id] = volume.current }
            let target = mute ? 0 : restoreLevel(id, volume)
            if !mute {
                // In case the mute is real after all and was misjudged. A
                // monitor drops a command that follows another at once, so
                // leave a gap before the volume.
                guard allowed() else { return .obsolete }
                _ = channel.write(.mute, value: 2)
                usleep(50000)
            }
            for _ in 0..<2 {
                usleep(10000)
                guard allowed() else { return .obsolete }
                _ = channel.write(.volume, value: target)
            }
            for pause: useconds_t in [50000, 250000] {
                usleep(pause)
                observed = read(.volume, on: endpoint, allowed: allowed)
                if let observed, (observed.current == 0) == mute { break }
            }
        } else if request.verifyOnly {
            observed = read(.volume, on: endpoint, allowed: allowed)
        }
        guard allowed() else { return .obsolete }
        guard let observed else { return .unconfirmed(nil) }
        endpoint.readings[.volume] = observed
        endpoints[id] = endpoint
        let muted = observed.current == 0
        return muted == mute ? .confirmed(muted ? 1 : 0) : .unconfirmed(muted ? 1 : 0)
    }

    func releaseConnections() {
        queue.async { [self] in endpoints.removeAll() }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func scan(_ screens: [ScreenDescription], session: Session) async -> [MonitorDisplay] {
        await perform { [self] in
            guard fence.accepts(session) else { return [] }
            let ordered = discover(screens)
            endpoints = Dictionary(uniqueKeysWithValues: ordered.map { ($0.display.id, $0) })
            let ids = ordered.map(\.display.id)
            guard readValues(ids: ids, session: session) != nil else { return [] }
            for id in ids { probeMute(id, session: session) }
            return ids.compactMap { endpoints[$0].map(snapshot) }
        }
    }

    func refresh(ids: [String], session: Session) async -> [MonitorDisplay]? {
        await perform { [self] in readValues(ids: ids, session: session, yieldsToWrites: true) }
    }

    private func read(_ feature: Feature, on endpoint: Endpoint, allowed: () -> Bool) -> DDCValue? {
        guard allowed(), isOnline(endpoint.display.screenID) else { return nil }
        if feature == .brightness && endpoint.appleBrightness {
            var value: Float = 0
            guard MCGetNativeBrightness(endpoint.display.screenID, &value) else { return nil }
            return DDCValue(current: UInt16((value * 10000).rounded()), maximum: 10000)
        }
        guard let channel = endpoint.channel else { return nil }
        // A busy or waking panel can drop a request or answer with a stale
        // frame. Pause before asking again so it is not the same collision.
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20000) }
            guard allowed(), isOnline(endpoint.display.screenID) else { return nil }
            guard let bytes = channel.read(feature) else { continue }
            switch DDCValue.parse(bytes, for: feature, allowsLGQuirk: endpoint.allowsLGQuirk) {
            case let .value(value): return value
            case .unsupported: return nil
            case .invalid: continue
            }
        }
        return nil
    }

    private func readValues(ids: [String], session: Session, yieldsToWrites: Bool = false) -> [MonitorDisplay]? {
        let interrupted = { yieldsToWrites && self.fence.isWriteWaiting }
        var displays: [MonitorDisplay] = []
        for id in ids {
            guard fence.accepts(session), var endpoint = endpoints[id] else { continue }
            for feature in Feature.allCases {
                let value = read(feature, on: endpoint) { self.fence.accepts(session) && !interrupted() }
                // A read that was cut short says nothing about the control.
                if interrupted() { return nil }
                endpoint.readings[feature] = value
            }
            // A register that reads a new value is not stuck. Judge it again.
            if let stuck = muteRegisters[id], stuck != 0, let mute = endpoint.readings[.mute], Int(mute.current) != stuck {
                remember(mute: nil, for: endpoint)
            }
            endpoint.mutesByVolume = (muteRegisters[id] ?? 0) != 0 && endpoint.readings[.volume] != nil
            endpoints[id] = endpoint
            displays.append(snapshot(endpoint))
        }
        return displays
    }

    func write(_ request: DisplayWrite, session: Session) async -> WriteResult {
        await perform { [self] in
            let key = request.key
            let fraction = request.fraction
            let allowed = { [self] in request.isCurrent(fence: fence, session: session) }
            guard allowed() else { return .obsolete }
            guard fraction.isFinite, (0...1).contains(fraction), var endpoint = endpoints[key.id],
                  let previous = endpoint.readings[key.feature],
                  isOnline(endpoint.display.screenID) else {
                return .unconfirmed(nil)
            }
            let target = key.feature == .mute ? UInt16(fraction == 0 ? 2 : 1) : UInt16((fraction * Double(previous.maximum)).rounded())
            guard allowed() else { return .obsolete }
            if key.feature == .mute && endpoint.mutesByVolume {
                return writeMuteByVolume(request, endpoint: endpoint, allowed: allowed)
            }
            // MonitorControl spaces and repeats Set VCP just as it does Get
            // VCP. The LG can acknowledge a lone transfer without applying it.
            let native = key.feature == .brightness && endpoint.appleBrightness
            var sent = request.verifyOnly
            if !request.verifyOnly {
                if native {
                    sent = MCSetNativeBrightness(endpoint.display.screenID, Float(fraction))
                } else if let channel = endpoint.channel {
                    for _ in 0..<2 {
                        usleep(10000)
                        guard allowed() else { return .obsolete }
                        if channel.write(key.feature, value: target) { sent = true }
                    }
                }
                // During a drag or a held key, leave the bus free for the next
                // level. The controller verifies the last one after input settles.
                if sent { return .sent }
            }
            var observed = read(key.feature, on: endpoint, allowed: allowed)
            // A panel can keep reporting the previous value for a moment
            // after it accepts a write. Give it a longer second chance.
            for pause: useconds_t in [50000, 250000] {
                guard sent, allowed(),
                      !DDCValue.confirmed(observed, target: target, feature: key.feature, lg: endpoint.allowsLGQuirk) else { break }
                usleep(pause)
                observed = read(key.feature, on: endpoint, allowed: allowed)
            }
            guard allowed() else { return .obsolete }
            if let observed { endpoint.readings[key.feature] = observed }
            endpoints[key.id] = endpoint
            let value = observed.map { key.feature == .mute ? ($0.current == 1 ? 1.0 : 0.0) : $0.fraction }
            let confirmed = native ? value.map { abs($0 - fraction) <= 0.01 } == true :
                DDCValue.confirmed(observed, target: target, feature: key.feature, lg: endpoint.allowsLGQuirk)
            if key.feature == .mute, let observed {
                if sent, confirmed {
                    remember(mute: 0, for: endpoint)
                } else if request.resent, endpoint.readings[.volume] != nil {
                    // Sent twice and read back unchanged: this mute does nothing.
                    remember(mute: Int(observed.current), for: endpoint)
                    endpoint.mutesByVolume = true
                    endpoints[key.id] = endpoint
                    var again = request
                    again.verifyOnly = false
                    return writeMuteByVolume(again, endpoint: endpoint, allowed: allowed)
                }
            }
            if sent, confirmed, let value { return .confirmed(value) }
            return .unconfirmed(value)
        }
    }
}
