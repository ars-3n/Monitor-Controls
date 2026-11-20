import AppKit
import Observation

private final class DisplayChangeListener: @unchecked Sendable {
    let fence: SessionFence
    let didChange: @MainActor @Sendable () -> Void

    init(fence: SessionFence, didChange: @escaping @MainActor @Sendable () -> Void) {
        self.fence = fence
        self.didChange = didChange
    }
}

private let configurationChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else { return }
    let listener = Unmanaged<DisplayChangeListener>.fromOpaque(context).takeUnretainedValue()
    listener.fence.resetDisplays()
    if !flags.contains(.beginConfigurationFlag) {
        Task { @MainActor in listener.didChange() }
    }
}

@MainActor @Observable
public final class DisplayController {
    public private(set) var displays: [MonitorDisplay] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?
    @ObservationIgnored public var onTopologyChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let worker: any DisplayIO
    @ObservationIgnored private let screens: @MainActor () -> [ScreenDescription]
    @ObservationIgnored private var listener: DisplayChangeListener?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var visibleSession: Session?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var scanPending = false
    @ObservationIgnored private var readPending = false
    @ObservationIgnored private var writes: [ControlKey: Double] = [:]
    @ObservationIgnored private var writeOrder: [ControlKey] = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var settle: Task<Void, Never>?

    public init() {
        worker = DisplayWorker()
        screens = ScreenDescription.collect
    }

    init(worker: any DisplayIO, screens: @escaping @MainActor () -> [ScreenDescription]) {
        self.worker = worker
        self.screens = screens
    }

    isolated deinit { stop() }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let listener = DisplayChangeListener(fence: worker.fence) { [weak self] in self?.reconfigure() }
        if CGDisplayRegisterReconfigurationCallback(configurationChanged, Unmanaged.passUnretained(listener).toOpaque()) == .success {
            self.listener = listener
        }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event == NSWorkspace.willSleepNotification || event == NSWorkspace.screensDidSleepNotification {
                        self.sleeping = true
                        self.invalidateTopology()
                    } else {
                        self.sleeping = false
                        self.reconfigure()
                    }
                }
            }
            observers.append(token)
        }
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        if let listener {
            CGDisplayRemoveReconfigurationCallback(configurationChanged, Unmanaged.passUnretained(listener).toOpaque())
        }
        listener = nil
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
        isRunning = false
        sleeping = false
        invalidateTopology()
    }

    private func invalidateTopology() {
        worker.fence.resetDisplays()
        worker.releaseConnections()
        settle?.cancel()
        settle = nil
        writes.removeAll()
        writeOrder.removeAll()
        scanPending = false
        readPending = false
        visibleSession = nil
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
            guard let self else { return }
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

    public func refreshValues() {
        guard isRunning, !sleeping, !isRefreshing, !displays.isEmpty else { return }
        readPending = true
        schedule()
    }

    public func cancelPendingAudioWrites() {
        worker.fence.resetAudio()
        writes = writes.filter { !$0.key.feature.isAudio }
        writeOrder.removeAll { $0.feature.isAudio }
        // If an optimistic speaker value was on screen, replace it from hardware.
        refreshValues()
    }

    public func dismissError() { lastError = nil }

    public func setBrightness(_ value: Double, for id: String) { enqueue(.brightness, value, id) }
    public func setVolume(_ value: Double, for id: String) { enqueue(.volume, value, id) }
    public func setMuted(_ muted: Bool, for id: String) { enqueue(.mute, muted ? 1 : 0, id) }

    private func enqueue(_ feature: Feature, _ value: Double, _ id: String) {
        guard isRunning, !sleeping, !isRefreshing, value.isFinite,
              let visibleSession, worker.fence.accepts(visibleSession),
              let index = displays.firstIndex(where: { $0.id == id }),
              displays[index].value(feature) != nil else { return }
        let bounded = min(1, max(0, value))
        let key = ControlKey(id: id, feature: feature)
        if writes[key] == nil { writeOrder.append(key) }
        writes[key] = bounded
        displays[index].apply(bounded, to: feature)
        schedule()
    }

    private func schedule() {
        guard pump == nil else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { pump = nil }
        while isRunning && !sleeping {
            let session = worker.fence.snapshot()
            if scanPending {
                scanPending = false
                let result = await worker.scan(screens(), session: session)
                if worker.fence.accepts(session) {
                    visibleSession = session
                    displays = result
                    isRefreshing = false
                }
            } else if let key = writeOrder.first {
                writeOrder.removeFirst()
                guard let fraction = writes.removeValue(forKey: key),
                      let visibleSession, worker.fence.accepts(visibleSession) else { continue }
                let result = await worker.write(key, fraction: fraction, session: session)
                guard worker.fence.accepts(session, audio: key.feature.isAudio),
                      writes[key] == nil, let index = displays.firstIndex(where: { $0.id == key.id }) else { continue }
                displays[index].apply(result.value, to: key.feature)
                if !result.success {
                    lastError = "Couldn’t confirm the change on " + displays[index].name + "."
                }
            } else if readPending {
                readPending = false
                let result = await worker.refresh(ids: displays.map(\.id), session: session)
                guard worker.fence.accepts(session) else { continue }
                // Keep newer slider movements visible while the hardware catches up.
                displays = result.map { display in
                    var updated = display
                    for (key, value) in writes where key.id == display.id { updated.apply(value, to: key.feature) }
                    return updated
                }
            } else {
                return
            }
        }
    }

    public func waitUntilIdle() async {
        while true {
            if let settle { await settle.value }
            else if let pump { await pump.value }
            else { return }
        }
    }
}
