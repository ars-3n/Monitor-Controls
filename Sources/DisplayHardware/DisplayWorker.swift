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

    func snapshot() -> Session { lock.withLock { current } }
    func resetDisplays() { lock.withLock { current.topology &+= 1 } }
    func resetAudio() { lock.withLock { current.audioRoute &+= 1 } }
    func accepts(_ session: Session, audio: Bool = false) -> Bool {
        lock.withLock { current.topology == session.topology && (!audio || current.audioRoute == session.audioRoute) }
    }
}

struct ControlKey: Hashable, Sendable {
    let id: String
    let feature: Feature
}

struct WriteResult: Sendable {
    let value: Double?
    let success: Bool
}

// All handles and register ranges are confined to this serial queue. Each
// operation can block on I²C without occupying the main actor or a Swift
// cooperative-executor thread.
protocol DisplayIO: Sendable {
    var fence: SessionFence { get }
    func releaseConnections()
    func scan(_ screens: [ScreenDescription], session: Session) async -> [MonitorDisplay]
    func refresh(ids: [String], session: Session) async -> [MonitorDisplay]
    func write(_ key: ControlKey, fraction: Double, session: Session) async -> WriteResult
}

final class DisplayWorker: DisplayIO, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DisplayHardware.DDC", qos: .userInitiated)
    private var endpoints: [String: Endpoint] = [:]
    let fence = SessionFence()

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
            let ordered = Discovery.endpoints(screens)
            endpoints = Dictionary(uniqueKeysWithValues: ordered.map { ($0.display.id, $0) })
            return readValues(ids: ordered.map(\.display.id), session: session)
        }
    }

    func refresh(ids: [String], session: Session) async -> [MonitorDisplay] {
        await perform { [self] in readValues(ids: ids, session: session) }
    }

    private func read(_ feature: Feature, on endpoint: Endpoint, allowed: () -> Bool) -> DDCValue? {
        guard allowed(), CGDisplayIsOnline(endpoint.display.screenID) != 0 else { return nil }
        if feature == .brightness && endpoint.appleBrightness {
            var value: Float = 0
            guard MCGetNativeBrightness(endpoint.display.screenID, &value) else { return nil }
            return DDCValue(current: UInt16((value * 10000).rounded()), maximum: 10000)
        }
        guard let channel = endpoint.channel else { return nil }
        var bytes = [UInt8](repeating: 0, count: 11)
        for _ in 0..<2 {
            guard allowed(), CGDisplayIsOnline(endpoint.display.screenID) != 0 else { return nil }
            if MCReadFeature(channel.handle, feature.rawValue, &bytes),
               let value = DDCValue.decode(bytes, for: feature, allowsLGQuirk: endpoint.allowsLGQuirk) { return value }
            // Unsupported responses are stable until the next refresh.
            if bytes[2] == 2 && bytes[3] == 1 && bytes[4] == feature.rawValue { break }
        }
        return nil
    }

    private func readValues(ids: [String], session: Session) -> [MonitorDisplay] {
        ids.compactMap { id in
            guard fence.accepts(session), var endpoint = endpoints[id] else { return nil }
            var display = endpoint.display
            for feature in Feature.allCases {
                let value = read(feature, on: endpoint) { self.fence.accepts(session) }
                endpoint.readings[feature] = value
                display.apply(value.map { feature == .mute ? ($0.current == 1 ? 1 : 0) : $0.fraction }, to: feature)
            }
            endpoints[id] = endpoint
            return display
        }
    }

    func write(_ key: ControlKey, fraction: Double, session: Session) async -> WriteResult {
        await perform { [self] in
            let allowed = { [self] in fence.accepts(session, audio: key.feature.isAudio) }
            guard allowed(), var endpoint = endpoints[key.id],
                  let previous = endpoint.readings[key.feature],
                  CGDisplayIsOnline(endpoint.display.screenID) != 0 else {
                return WriteResult(value: nil, success: false)
            }
            let target = key.feature == .mute ? UInt16(fraction == 0 ? 2 : 1) : UInt16((fraction * Double(previous.maximum)).rounded())
            guard allowed() else { return WriteResult(value: nil, success: false) }
            // MonitorControl spaces and repeats Set VCP just as it does Get
            // VCP. The LG can acknowledge a lone transfer without applying it.
            var sent = false
            let native = key.feature == .brightness && endpoint.appleBrightness
            if native {
                sent = MCSetNativeBrightness(endpoint.display.screenID, Float(fraction))
            } else if let channel = endpoint.channel {
                for _ in 0..<2 {
                    usleep(10000)
                    guard allowed() else { return WriteResult(value: nil, success: false) }
                    if MCWriteFeature(channel.handle, key.feature.rawValue, target) { sent = true }
                }
            }
            // A successful bus transfer alone does not prove the monitor
            // applied the value. Give the panel time to commit, then confirm.
            usleep(40000)
            var observed = read(key.feature, on: endpoint, allowed: allowed)
            if sent, !DDCValue.confirmed(observed, target: target, feature: key.feature, lg: endpoint.allowsLGQuirk), allowed() {
                usleep(50000)
                observed = read(key.feature, on: endpoint, allowed: allowed)
            }
            guard allowed() else { return WriteResult(value: nil, success: false) }
            if let observed { endpoint.readings[key.feature] = observed }
            endpoints[key.id] = endpoint
            let value = observed.map { key.feature == .mute ? ($0.current == 1 ? 1.0 : 0.0) : $0.fraction }
            let confirmed = native ? value.map { abs($0 - fraction) <= 0.01 } == true :
                DDCValue.confirmed(observed, target: target, feature: key.feature, lg: endpoint.allowsLGQuirk)
            return WriteResult(value: value, success: sent && confirmed)
        }
    }
}
