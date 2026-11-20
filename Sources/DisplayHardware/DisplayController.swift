import AppKit
import Observation
import os

// CoreGraphics holds an unowned context. Use a non-reused numeric identifier
// so a callback already in flight can safely arrive after stop or restart.
private enum DisplayCallbacks {
    struct Listener: Sendable {
        let fence: SessionFence
        let didChange: @MainActor @Sendable () -> Void
    }

    private struct State {
        var sequence: UInt = 0
        var listeners: [UInt: Listener] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func register(fence: SessionFence, didChange: @escaping @MainActor @Sendable () -> Void) -> UInt? {
        let id = state.withLock {
            $0.sequence += 1
            $0.listeners[$0.sequence] = Listener(fence: fence, didChange: didChange)
            return $0.sequence
        }
        guard CGDisplayRegisterReconfigurationCallback(configurationChanged, UnsafeMutableRawPointer(bitPattern: id)) == .success else {
            state.withLock { $0.listeners[id] = nil }
            return nil
        }
        return id
    }

    static func remove(_ id: UInt) {
        state.withLock { $0.listeners[id] = nil }
        CGDisplayRemoveReconfigurationCallback(configurationChanged, UnsafeMutableRawPointer(bitPattern: id))
    }

    static func received(_ id: UInt, flags: CGDisplayChangeSummaryFlags) {
        let registered = state.withLock {
            guard let listener = $0.listeners[id] else { return false }
            listener.fence.resetDisplays()
            return true
        }
        if registered && !flags.contains(.beginConfigurationFlag) {
            Task { @MainActor in state.withLock { $0.listeners[id] }?.didChange() }
        }
    }
}

private let configurationChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    if let context { DisplayCallbacks.received(UInt(bitPattern: context), flags: flags) }
}

@MainActor @Observable
public final class DisplayController {
    public private(set) var displays: [MonitorDisplay] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?
    @ObservationIgnored public var onTopologyChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let worker: any DisplayIO
    @ObservationIgnored private let screens: @MainActor () -> [ScreenDescription]
    @ObservationIgnored private var registration: UInt?
    @ObservationIgnored private let observesSystemEvents: Bool
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var visibleSession: Session?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var systemSleeping = false
    @ObservationIgnored private var screensSleeping = false
    private var sleeping: Bool { systemSleeping || screensSleeping }
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private let recoveryDelays: [Duration]
    @ObservationIgnored private var knownFeatures: [String: Set<Feature>] = [:]
    @ObservationIgnored private var expectedDisplayCountAfterWake = 0
    @ObservationIgnored private var scanPending = false
    @ObservationIgnored private var readPending = false
    @ObservationIgnored private var confirmed: [String: MonitorDisplay] = [:]
    @ObservationIgnored private var failedKey: ControlKey?
    @ObservationIgnored private var writes: [ControlKey: DisplayWrite] = [:]
    @ObservationIgnored private var writeOrder: [ControlKey] = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var brightnessChecks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private let staleAfter: Duration
    @ObservationIgnored private var synced: ContinuousClock.Instant?
    @ObservationIgnored private var waiting: [@MainActor () -> Void] = []

    public init() {
        worker = DisplayWorker()
        observesSystemEvents = true
        screens = ScreenDescription.collect
        recoveryDelays = [.milliseconds(700), .seconds(2)]
        staleAfter = .seconds(10)
    }

    init(worker: any DisplayIO, recoveryDelays: [Duration] = [], staleAfter: Duration = .seconds(10),
         screens: @escaping @MainActor () -> [ScreenDescription]) {
        self.worker = worker
        observesSystemEvents = false
        self.screens = screens
        self.recoveryDelays = recoveryDelays
        self.staleAfter = staleAfter
    }

    isolated deinit { stop() }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        if observesSystemEvents { observeSystemEvents() }
        refresh()
    }

    private func observeSystemEvents() {
        registration = DisplayCallbacks.register(fence: worker.fence) { [weak self] in self?.reconfigure() }
        if registration == nil {
            let center = NotificationCenter.default
            let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconfigure() }
            }
            observers.append((center, token))
        }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.powerChanged(event)
                }
            }
            observers.append((center, token))
        }
    }

    public func stop() {
        guard isRunning else { return }
        if let registration { DisplayCallbacks.remove(registration) }
        registration = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        isRunning = false
        systemSleeping = false
        screensSleeping = false
        expectedDisplayCountAfterWake = 0
        invalidateTopology()
    }

    func powerChanged(_ event: Notification.Name) {
        guard isRunning else { return }
        let wasSleeping = sleeping
        switch event {
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        default: return
        }
        if sleeping && !wasSleeping {
            expectedDisplayCountAfterWake = max(expectedDisplayCountAfterWake, displays.count)
            invalidateTopology()
        } else if !sleeping {
            reconfigure()
        }
    }

    private func invalidateTopology() {
        worker.fence.resetDisplays()
        worker.releaseConnections()
        settle?.cancel()
        settle = nil
        recovery?.cancel()
        recovery = nil
        recoveryAttempts = 0
        for check in brightnessChecks.values { check.cancel() }
        brightnessChecks.removeAll()
        writes.removeAll()
        writeOrder.removeAll()
        waiting.removeAll()
        synced = nil
        scanPending = false
        readPending = false
        for display in displays where !display.canRememberPairing { knownFeatures.removeValue(forKey: display.id) }
        visibleSession = nil
        confirmed.removeAll()
        dismissError()
        displays = []
        isRefreshing = false
        onTopologyChanged?()
    }

    private func reconfigure() {
        guard isRunning else { return }
        invalidateTopology()
        guard !sleeping else { return }
        isRefreshing = true
        // One physical connection can emit several reconfiguration callbacks.
        settle = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.settle = nil
            self.scanPending = true
            self.schedule()
        }
    }

    public func refresh() {
        guard isRunning, !sleeping else { return }
        invalidateTopology()
        isRefreshing = true
        scanPending = true
        schedule()
    }

    /// Pass `userIsPresent` when the user opened the panel themselves.
    public func refreshValues(userIsPresent: Bool = false) {
        guard isRunning else { return }
        if userIsPresent && sleeping {
            // Someone is using the screen, so a wake notification never
            // arrived. Without this the controller stays idle until relaunch.
            systemSleeping = false
            screensSleeping = false
            reconfigure()
            return
        }
        guard !sleeping, !isRefreshing else { return }
        // CoreGraphics can see the screen before the dock creates its DDC
        // service. Reopening the panel must be able to acquire a new handle.
        recovery?.cancel()
        recovery = nil
        readPending = true
        schedule()
    }

    public func cancelPendingAudioWrites() {
        worker.fence.resetAudio()
        writes = writes.filter { !$0.key.feature.isAudio }
        writeOrder.removeAll { $0.feature.isAudio }
        // Immediately remove optimistic levels for the old route. A later
        // read verifies whether a transfer already on the wire did take effect.
        for i in displays.indices {
            if let last = confirmed[displays[i].id] {
                displays[i].volume = last.volume
                displays[i].muted = last.muted
            }
        }
        refreshValues()
    }

    private var needsDiscovery: Bool {
        if confirmed.isEmpty { return true }
        return confirmed.values.contains { display in
            let features = Set(Feature.allCases.filter { display.value($0) != nil })
            return features.isEmpty || !(knownFeatures[display.id] ?? []).isSubset(of: features)
        }
    }

    private func didRead(_ result: [MonitorDisplay]) {
        if result.count >= expectedDisplayCountAfterWake { expectedDisplayCountAfterWake = 0 }
        for display in result {
            let features = Feature.allCases.filter { display.value($0) != nil }
            knownFeatures[display.id, default: []].formUnion(features)
        }
        guard expectedDisplayCountAfterWake > 0 || needsDiscovery else {
            recoveryAttempts = 0
            return
        }
        guard recoveryAttempts < recoveryDelays.count else {
            expectedDisplayCountAfterWake = 0
            return
        }
        guard (expectedDisplayCountAfterWake > 0 || !displays.isEmpty), recovery == nil else { return }
        let delay = recoveryDelays[recoveryAttempts]
        recoveryAttempts += 1
        recovery = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.recovery = nil
            self.readPending = true
            self.schedule()
        }
    }

    /// Runs `change` against levels read from the monitor recently. The
    /// monitor's own buttons, or another computer on a second input, may have
    /// moved them since the last read, so an old reading is refreshed first.
    public func withCurrentLevels(_ change: @escaping @MainActor () -> Void) {
        guard isRunning, !sleeping, !isRefreshing, !displays.isEmpty,
              synced.map({ $0.duration(to: .now) >= staleAfter }) ?? true else { return change() }
        waiting.append(change)
        readPending = true
        schedule()
    }

    private func resumeWaiting() {
        let changes = waiting
        waiting.removeAll()
        for change in changes { change() }
    }

    public func dismissError() {
        failedKey = nil
        lastError = nil
    }

    public func setBrightness(_ value: Double, for id: String) { enqueue(.brightness, value, id) }
    public func setVolume(_ value: Double, for id: String, while routeIsCurrent: (@Sendable () -> Bool)? = nil) {
        enqueue(.volume, value, id, routeIsCurrent: routeIsCurrent)
    }
    public func setMuted(_ muted: Bool, for id: String, while routeIsCurrent: (@Sendable () -> Bool)? = nil) {
        enqueue(.mute, muted ? 1 : 0, id, routeIsCurrent: routeIsCurrent)
    }

    private func enqueue(_ feature: Feature, _ value: Double, _ id: String,
                         routeIsCurrent: (@Sendable () -> Bool)? = nil) {
        guard isRunning, !sleeping, !isRefreshing, value.isFinite,
              let visibleSession, worker.fence.accepts(visibleSession),
              let index = displays.firstIndex(where: { $0.id == id }),
              displays[index].value(feature) != nil else { return }
        let bounded = min(1, max(0, value))
        let key = ControlKey(id: id, feature: feature)
        if feature == .brightness { brightnessChecks.removeValue(forKey: id)?.cancel() }
        if writes[key] == nil { writeOrder.append(key) }
        writes[key] = DisplayWrite(key: key, fraction: bounded, routeIsCurrent: routeIsCurrent)
        displays[index].apply(bounded, to: feature)
        synced = .now
        schedule()
    }

    private func scheduleBrightnessCheck(_ request: DisplayWrite, session: Session) {
        let key = request.key
        brightnessChecks[key.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.brightnessChecks[key.id] = nil
            guard self.worker.fence.accepts(session) else { return }
            var check = request
            check.verifyBrightnessOnly = true
            self.writes[key] = check
            self.writeOrder.append(key)
            self.schedule()
        }
    }

    private func schedule() {
        guard pump == nil else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        // A read that never ran must not strand the changes waiting for it.
        defer {
            pump = nil
            resumeWaiting()
        }
        while isRunning && !sleeping {
            let session = worker.fence.snapshot()
            if scanPending {
                scanPending = false
                let result = await worker.scan(screens(), session: session)
                if worker.fence.accepts(session) {
                    visibleSession = session
                    confirmed = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
                    displays = result
                    isRefreshing = false
                    synced = .now
                    didRead(result)
                    resumeWaiting()
                }
            } else if let key = writeOrder.first {
                writeOrder.removeFirst()
                guard let request = writes.removeValue(forKey: key),
                      let visibleSession, worker.fence.accepts(visibleSession) else { continue }
                let result = await worker.write(request, session: session)
                guard worker.fence.accepts(session, audio: key.feature.isAudio),
                      let index = displays.firstIndex(where: { $0.id == key.id }) else { continue }
                switch result {
                case .sentBrightness:
                    if writes[key] == nil { scheduleBrightnessCheck(request, session: session) }
                case let .confirmed(value):
                    confirmed[key.id]?.apply(value, to: key.feature)
                    if writes[key] == nil { displays[index].apply(value, to: key.feature) }
                    if failedKey == key { dismissError() }
                case let .unconfirmed(value):
                    if let value { confirmed[key.id]?.apply(value, to: key.feature) }
                    guard writes[key] == nil else { continue }
                    displays[index].apply(value, to: key.feature)
                    failedKey = key
                    lastError = "Couldn’t confirm the change on " + displays[index].name + "."
                    if value == nil { readPending = true }
                case .obsolete:
                    // Core Audio may switch outputs before delivering its notification.
                    if writes[key] == nil {
                        displays[index].apply(confirmed[key.id]?.value(key.feature), to: key.feature)
                    }
                    readPending = true
                }
            } else if readPending && brightnessChecks.isEmpty {
                readPending = false
                let result: [MonitorDisplay]
                let current = screens()
                if Set(current.map(\.screenID)) != Set(displays.map(\.screenID)) {
                    // A dock can expose displays in stages after wake without
                    // delivering a second display reconfiguration callback.
                    refresh()
                    continue
                }
                if needsDiscovery {
                    result = await worker.scan(current, session: session)
                } else {
                    result = await worker.refresh(ids: displays.map(\.id), session: session)
                }
                guard worker.fence.accepts(session) else { continue }
                confirmed = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
                // Keep newer slider movements visible while the hardware catches up.
                displays = result.map { display in
                    var updated = display
                    for (key, request) in writes where key.id == display.id { updated.apply(request.fraction, to: key.feature) }
                    return updated
                }
                synced = .now
                didRead(result)
                resumeWaiting()
            } else {
                return
            }
        }
    }

    public func waitUntilIdle() async {
        while true {
            if let settle { await settle.value }
            else if let pump { await pump.value }
            else if let check = brightnessChecks.values.first { await check.value }
            else if let recovery { await recovery.value }
            else { return }
        }
    }
}
