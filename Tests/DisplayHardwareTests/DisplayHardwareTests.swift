import AppKit
import CoreGraphics
import os
import Testing
@testable import DisplayHardware

private extension DDCValue {
    static func decode(_ bytes: [UInt8], for feature: Feature, allowsLGQuirk: Bool) -> Self? {
        guard case let .value(value) = parse(bytes, for: feature, allowsLGQuirk: allowsLGQuirk) else { return nil }
        return value
    }
}

@Suite struct HardwareProtocolTests {
    let lgBrightness: [UInt8] = [0x6e, 0, 2, 0, 0x10, 0, 0, 100, 0, 25, 0xd9]
    let lgVolume: [UInt8] = [0x6e, 0, 2, 0, 0x62, 0, 0, 100, 0, 12, 0xbe]
    let lgMute: [UInt8] = [0x6e, 0, 2, 0, 0x8d, 0, 0, 100, 0, 2, 0x5f]

    @Test func observedLGRepliesRequireAnExplicitQuirk() {
        #expect(DDCValue.decode(lgBrightness, for: .brightness, allowsLGQuirk: true)?.fraction == 0.25)
        #expect(DDCValue.decode(lgVolume, for: .volume, allowsLGQuirk: true)?.fraction == 0.12)
        #expect(DDCValue.decode(lgMute, for: .mute, allowsLGQuirk: true)?.current == 2)
        #expect(DDCValue.decode(lgBrightness, for: .brightness, allowsLGQuirk: false) == nil)
        var normal = lgBrightness
        normal[1] = 0x88
        #expect(DDCValue.decode(normal, for: .brightness, allowsLGQuirk: false)?.current == 25)
    }

    @Test func malformedOrStaleRepliesCannotDriveThePanel() {
        #expect(DDCValue.decode(lgBrightness, for: .volume, allowsLGQuirk: true) == nil)
        for index in lgBrightness.indices {
            var corrupt = lgBrightness
            corrupt[index] ^= 0x01
            #expect(DDCValue.decode(corrupt, for: .brightness, allowsLGQuirk: true) == nil)
        }
        #expect(DDCValue.decode(Array(lgVolume.dropLast()), for: .volume, allowsLGQuirk: true) == nil)
    }

    @Test func unsupportedAndOutOfRangeValuesAreRejectedEvenWithValidChecksum() {
        func reply(feature: UInt8, status: UInt8, max: UInt16, value: UInt16) -> [UInt8] {
            let bytes: [UInt8] = [0x6e, 0x88, 2, status, feature, 0, UInt8(max >> 8),
                                  UInt8(truncatingIfNeeded: max), UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
            return bytes + [bytes.reduce(UInt8(0x50), ^)]
        }
        #expect(DDCValue.decode(reply(feature: 0x10, status: 1, max: 100, value: 20), for: .brightness, allowsLGQuirk: false) == nil)
        #expect(DDCValue.decode(reply(feature: 0x10, status: 0, max: 0, value: 0), for: .brightness, allowsLGQuirk: false) == nil)
        #expect(DDCValue.decode(reply(feature: 0x10, status: 0, max: 100, value: 120), for: .brightness, allowsLGQuirk: false) == nil)
        #expect(DDCValue.decode(reply(feature: 0x8d, status: 0, max: 0, value: 0), for: .mute, allowsLGQuirk: false) == nil)
        #expect(DDCValue.decode(reply(feature: 0x62, status: 0, max: 1000, value: 500), for: .volume, allowsLGQuirk: false)?.fraction == 0.5)
    }
}

@Suite struct DisplayIdentityTests {
    func screen(_ id: UInt32, serial: UInt32 = 0, path: String? = nil) -> ScreenDescription {
        ScreenDescription(screenID: id, name: "LG ULTRAWIDE", vendor: 1, product: 123,
                          serial: serial, uuid: "same CG UUID", location: path)
    }

    @Test func duplicateDisplaysAreOnlyMatchedWhenUnambiguous() {
        let left = ServiceIdentity(productName: "LG ULTRAWIDE", framebufferPath: "/left", serial: 0)
        let right = ServiceIdentity(productName: "LG ULTRAWIDE", framebufferPath: "/right", serial: 0)
        #expect(ServiceIdentity.matches(screens: [screen(1), screen(2)], services: [right, left]).isEmpty)
        #expect(ServiceIdentity.matches(screens: [screen(1), screen(2)], services: [left]).isEmpty)
        #expect(ServiceIdentity.matches(screens: [screen(1, path: "/left"), screen(2, path: "/right")],
                                       services: [right, left]) == [0: 1, 1: 0])
        #expect(ServiceIdentity.matches(screens: [screen(1, serial: 5)], services: [
            ServiceIdentity(productName: "LG ULTRAWIDE", framebufferPath: "/port", serial: 6)]).isEmpty)
    }

    @Test func ambiguousIdenticalPanelsUseSessionIdentities() {
        let one = screen(1), two = screen(2)
        #expect(Discovery.stableID(for: one, among: [one, two]).id != Discovery.stableID(for: two, among: [one, two]).id)
        #expect(!Discovery.stableID(for: one, among: [one, two]).persistent)
        let before = screen(1, serial: 567), after = screen(99, serial: 567)
        #expect(Discovery.stableID(for: before, among: [before]).id == Discovery.stableID(for: after, among: [after]).id)
    }

    @Test func aPlaceholderDisplayUUIDCannotRememberSpeakerPairing() {
        let generic = ScreenDescription(screenID: 2, name: "Display", vendor: 1, product: 123,
                                        serial: 0, uuid: "00000000-0000-0000-0000-000000000000", location: nil)
        #expect(!Discovery.stableID(for: generic, among: [generic]).persistent)
    }

    @Test func sameModelWithoutSerialKeepsUniqueUUIDPairingsWhenADisplayDisconnects() {
        let left = screen(1)
        let right = ScreenDescription(screenID: 2, name: left.name, vendor: left.vendor, product: left.product,
                                      serial: 0, uuid: "second CG UUID", location: nil)
        for display in [left, right] {
            let together = Discovery.stableID(for: display, among: [left, right])
            let alone = Discovery.stableID(for: display, among: [display])
            #expect(together.persistent)
            #expect(together.id == alone.id)
        }
    }

    @Test func outputChangesCancelSpeakerWritesAndTopologyCancelsAllWrites() {
        let fence = SessionFence()
        let first = fence.snapshot()
        fence.resetAudio()
        #expect(!fence.accepts(first, audio: true))
        #expect(fence.accepts(first))
        let second = fence.snapshot()
        fence.resetDisplays()
        #expect(!fence.accepts(first))
        #expect(!fence.accepts(second, audio: true))
    }
}

@Test func lgSpeakerQuantizationIsLocalAndBounded() {
    let observed = DDCValue(current: 18, maximum: 100)
    #expect(DDCValue.confirmed(observed, target: 17, feature: .volume, lg: true))
    #expect(!DDCValue.confirmed(observed, target: 16, feature: .volume, lg: true))
    #expect(!DDCValue.confirmed(observed, target: 17, feature: .volume, lg: false))
    #expect(!DDCValue.confirmed(observed, target: 17, feature: .brightness, lg: true))
    #expect(!DDCValue.confirmed(nil, target: 17, feature: .volume, lg: true))
    let differentRange = DDCValue(current: 18, maximum: 200)
    #expect(!DDCValue.confirmed(differentRange, target: 17, feature: .volume, lg: true))
}

private actor TestDisplayIO: DisplayIO {
    nonisolated let fence = SessionFence()
    nonisolated func releaseConnections() {}
    var sent: [ControlKey] = []
    var display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: 0.25, volume: 0.18, muted: false)

    func changeOnTheMonitor(brightness: Double) { display.apply(brightness, to: .brightness) }

    var additionalDisplays: [MonitorDisplay] = []
    var scanCount = 0
    var scansWithoutControls = 0
    func makeUnavailable(for scans: Int) { scansWithoutControls = scans }
    func scan(_ screens: [ScreenDescription], session: Session) -> [MonitorDisplay] {
        scanCount += 1
        guard !screens.isEmpty else { return [] }
        if scansWithoutControls > 0 {
            scansWithoutControls -= 1
            var unready = display
            for feature in Feature.allCases { unready.apply(nil, to: feature) }
            return [unready]
        }
        additionalDisplays = screens.dropFirst().map { screen in
            MonitorDisplay(id: String(screen.screenID), screenID: screen.screenID, name: screen.name,
                           brightness: 0.5, volume: nil, muted: nil)
        }
        return [display] + additionalDisplays
    }
    var refreshCount = 0
    var interruptedReads = 0
    private var droppedWrites = 0
    func interruptNextRead() { interruptedReads = 1 }
    func refresh(ids: [String], session: Session) -> [MonitorDisplay]? {
        refreshCount += 1
        if interruptedReads > 0 {
            interruptedReads -= 1
            return nil
        }
        return [display] + additionalDisplays
    }
    func dropWrites(_ count: Int) { droppedWrites = count }
    func write(_ request: DisplayWrite, session: Session) -> WriteResult {
        guard request.isCurrent(fence: fence, session: session) else { return .obsolete }
        if request.verifyOnly {
            let value = display.value(request.key.feature)
            return value == request.fraction ? .confirmed(request.fraction) : .unconfirmed(value)
        }
        sent.append(request.key)
        if droppedWrites > 0 {
            droppedWrites -= 1
            return .sent
        }
        display.apply(request.fraction, to: request.key.feature)
        return .confirmed(request.fraction)
    }
}

@MainActor @Test func rapidSlidersCoalesceAndRouteChangesDropPendingSpeakerWrites() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    for value in 1...100 { controller.setBrightness(Double(value)/100, for: "lg") }
    controller.setVolume(0.55, for: "lg")
    controller.setMuted(true, for: "lg")
    controller.cancelPendingAudioWrites()
    #expect(controller.displays.first?.volume == 0.18)
    #expect(controller.displays.first?.muted == false)
    await controller.waitUntilIdle()
    #expect(await worker.sent == [ControlKey(id: "lg", feature: .brightness)])
    #expect(controller.displays.first?.brightness == 1)
    #expect(controller.displays.first?.volume == 0.18)
    #expect(controller.displays.first?.muted == false)
}

@MainActor @Test func aReadCutShortByAChangeIsRepeatedAndKeepsTheDisplays() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    await worker.changeOnTheMonitor(brightness: 0.5)
    await worker.interruptNextRead()
    controller.refreshValues()
    await controller.waitUntilIdle()
    #expect(await worker.refreshCount == 2)
    #expect(controller.displays.first?.brightness == 0.5)
}

private let deskScreen = ScreenDescription(screenID: 42, name: "LG", vendor: 1, product: 123, serial: 567,
                                           uuid: nil, location: nil)

@MainActor @Test func lateDDCServiceIsRediscoveredAfterWakeAndFromPanel() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker, recoveryDelays: [.milliseconds(1)]) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    controller.powerChanged(NSWorkspace.screensDidSleepNotification)
    controller.powerChanged(NSWorkspace.willSleepNotification)
    controller.powerChanged(NSWorkspace.didWakeNotification)
    controller.refreshValues()
    await controller.waitUntilIdle()
    #expect(controller.displays.isEmpty)
    #expect(await worker.scanCount == 1)

    await worker.makeUnavailable(for: 2)
    controller.powerChanged(NSWorkspace.screensDidWakeNotification)
    await controller.waitUntilIdle()
    #expect(await worker.scanCount == 3)
    #expect(controller.displays.first?.brightness == nil)
    // The retry budget is exhausted. A new panel opening can still bind the
    // hardware service when it finally arrives without another topology event.
    controller.refreshValues()
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.brightness == 0.25)
    #expect(await worker.scanCount == 4)
}

@MainActor @Test func wakeRecoversSecondDisplayAndPanelRefreshDetectsMissedDisconnect() async {
    let worker = TestDisplayIO()
    let second = ScreenDescription(screenID: 43, name: "Other monitor", vendor: 1, product: 234,
                                   serial: 789, uuid: nil, location: nil)
    @MainActor final class Inventory {
        var connected: [ScreenDescription] = []
        var firstScanAfterWake = false
    }
    let inventory = Inventory()
    inventory.connected = [deskScreen, second]
    let controller = DisplayController(worker: worker, recoveryDelays: [.milliseconds(1)]) {
        if inventory.firstScanAfterWake {
            inventory.firstScanAfterWake = false
            return [deskScreen]
        }
        return inventory.connected
    }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    #expect(controller.displays.map(\.screenID) == [42, 43])
    controller.powerChanged(NSWorkspace.screensDidSleepNotification)
    inventory.firstScanAfterWake = true
    controller.powerChanged(NSWorkspace.screensDidWakeNotification)
    await controller.waitUntilIdle()
    #expect(controller.displays.map(\.screenID) == [42, 43])

    inventory.connected = [deskScreen]
    controller.refreshValues()
    await controller.waitUntilIdle()
    #expect(controller.displays.map(\.screenID) == [42])
}

@Test func routeProbeCannotRevalidateAnExpiredTopology() {
    let fence = SessionFence()
    let request = DisplayWrite(key: ControlKey(id: "lg", feature: .volume), fraction: 0.3) {
        fence.resetDisplays()
        return true
    }
    let valid = request.isCurrent(fence: fence, session: fence.snapshot())
    #expect(!valid)
}

@Test func contradictoryOrAmbiguousFramebufferEvidenceIsNeverDowngradedToANameGuess() {
    let screen = ScreenDescription(screenID: 9, name: "LG", vendor: 1, product: 2, serial: 567,
                                  uuid: nil, location: "/current")
    let conflicting = ServiceIdentity(productName: "LG", framebufferPath: "/current", serial: 888)
    #expect(ServiceIdentity.matches(screens: [screen], services: [conflicting]).isEmpty)
    let exact = ServiceIdentity(productName: "LG", framebufferPath: "/current", serial: 567)
    let fallback = ServiceIdentity(productName: "LG", framebufferPath: "/different", serial: 0)
    #expect(ServiceIdentity.matches(screens: [screen], services: [exact, exact, fallback]).isEmpty)
}

private final class SimulatedChannel: DDCChannel, Sendable {
    struct State {
        var writes: [Feature] = []
        var routeCurrent = true
        var brightnessReads = 0
        var brightness: UInt8 = 25
        var brightnessTargets: [UInt16] = []
        var ignoresBrightness = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func read(_ feature: Feature) -> [UInt8]? {
        let firstBrightnessRead = state.withLock {
            if feature == .brightness { $0.brightnessReads += 1 }
            return feature == .brightness && $0.brightnessReads == 1
        }
        if firstBrightnessRead {
            // Looks like "unsupported" until its invalid checksum is examined.
            return [0x6e, 0x88, 2, 1, feature.rawValue, 0, 0, 100, 0, 0, 0]
        }
        let current: UInt8 = feature == .brightness ? state.withLock { $0.brightness } : (feature == .mute ? 2 : 25)
        let bytes: [UInt8] = [0x6e, 0x88, 2, 0, feature.rawValue, 0, 0, 100, 0, current]
        return bytes + [bytes.reduce(UInt8(0x50), ^)]
    }

    func write(_ feature: Feature, value: UInt16) -> Bool {
        state.withLock {
            $0.writes.append(feature)
            if feature == .brightness {
                $0.brightnessTargets.append(value)
                if !$0.ignoresBrightness { $0.brightness = UInt8(value) }
            }
            $0.routeCurrent = false // e.g. AirPods connected between the two bus transfers
        }
        return true
    }
}

@MainActor @Test func brightnessDragSendsLatestPositionAndChecksOnlyTheFinalValue() async {
    let channel = SimulatedChannel()
    let worker = DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: channel, allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true })
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    let initialReads = channel.state.withLock { $0.brightnessReads }

    controller.setBrightness(0.3, for: "lg")
    // Wait for the first real write so this exercises a drag across multiple
    // turns of the controller's pump, not just coalescing in a single turn.
    let deadline = ContinuousClock.now + .seconds(2)
    while channel.state.withLock({ $0.brightnessTargets.isEmpty }) && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    controller.setBrightness(0.4, for: "lg")
    controller.setBrightness(0.6, for: "lg")
    await controller.waitUntilIdle()
    #expect(channel.state.withLock { $0.brightnessTargets } == [30, 30, 60, 60])
    #expect(channel.state.withLock { $0.brightnessReads - initialReads } == 1)
    #expect(controller.displays.first?.brightness == 0.6)
    #expect(controller.lastError == nil)

    // A successful transfer may still be ignored by the monitor.
    channel.state.withLock { $0.ignoresBrightness = true }
    controller.setBrightness(0.8, for: "lg")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.brightness == 0.6)
    #expect(controller.lastError != nil)
}

@Test func outputChangeStopsTheSecondHardwareTransfer() async {
    let channel = SimulatedChannel()
    let worker = DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: channel, allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true })
    let session = worker.fence.snapshot()
    let displays = await worker.scan([deskScreen], session: session)
    #expect(displays.first?.brightness == 0.25)
    #expect(channel.state.withLock { $0.brightnessReads } == 2)
    let request = DisplayWrite(key: ControlKey(id: "lg", feature: .volume), fraction: 0.4) {
        channel.state.withLock { $0.routeCurrent }
    }
    let result = await worker.write(request, session: session)
    guard case .obsolete = result else { Issue.record("Stale audio route produced a write result"); return }
    #expect(channel.state.withLock { $0.writes } == [.volume])
}

@MainActor @Test func anUnmuteTheMonitorDroppedIsSentOnceMore() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    controller.setMuted(true, for: "lg")
    await controller.waitUntilIdle()

    await worker.dropWrites(1)
    controller.setMuted(false, for: "lg")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.muted == false)
    #expect(controller.lastError == nil)
    #expect(await worker.sent.filter { $0.feature == .mute }.count == 3)

    // A monitor that keeps refusing is reported, with the state it is really in.
    await worker.dropWrites(2)
    controller.setMuted(true, for: "lg")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.muted == false)
    #expect(controller.lastError != nil)
    #expect(await worker.sent.filter { $0.feature == .mute }.count == 5)
}

@MainActor @Test func expiredLiveRouteRestoresSpeakerValueWithoutAnError() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    controller.setVolume(0.5, for: "lg", while: { false })
    await controller.waitUntilIdle()
    #expect(await worker.sent.isEmpty)
    #expect(controller.displays.first?.volume == 0.18)
    #expect(controller.lastError == nil)
}

@MainActor @Test func openingThePanelRecoversFromAMissedWakeNotification() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    controller.powerChanged(NSWorkspace.willSleepNotification)
    controller.powerChanged(NSWorkspace.screensDidSleepNotification)
    // An audio route change during sleep must not wake the hardware.
    controller.refreshValues()
    await controller.waitUntilIdle()
    #expect(controller.displays.isEmpty)

    controller.refreshValues(userIsPresent: true)
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.brightness == 0.25)
    controller.setBrightness(0.5, for: "lg")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.brightness == 0.5)
}

/// Accepts a write at once and reports the previous value for two more reads.
private final class LaggingChannel: DDCChannel, Sendable {
    let state = OSAllocatedUnfairLock(initialState: (reported: UInt8(25), accepted: UInt8(25), staleReads: 0))

    func read(_ feature: Feature) -> [UInt8]? {
        let current: UInt8 = state.withLock {
            guard feature != .mute else { return 2 }
            if $0.staleReads > 0 { $0.staleReads -= 1 } else { $0.reported = $0.accepted }
            return $0.reported
        }
        let bytes: [UInt8] = [0x6e, 0x88, 2, 0, feature.rawValue, 0, 0, 100, 0, current]
        return bytes + [bytes.reduce(UInt8(0x50), ^)]
    }

    func write(_ feature: Feature, value: UInt16) -> Bool {
        state.withLock {
            $0.accepted = UInt8(value)
            $0.staleReads = 2
        }
        return true
    }
}

@Test func slowPanelGetsALaterReadBeforeTheChangeIsReportedAsFailed() async {
    let channel = LaggingChannel()
    let worker = DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: channel, allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true })
    let session = worker.fence.snapshot()
    _ = await worker.scan([deskScreen], session: session)
    // Brightness and volume are both sent first and read back afterwards.
    for feature in [Feature.brightness, .volume] {
        var request = DisplayWrite(key: ControlKey(id: "lg", feature: feature), fraction: 0.6, routeIsCurrent: nil)
        guard case .sent = await worker.write(request, session: session) else {
            Issue.record("The write was not sent"); return
        }
        request.verifyOnly = true
        guard case let .confirmed(value) = await worker.write(request, session: session) else {
            Issue.record("A panel that applied the change two reads late was reported as failed"); return
        }
        #expect(value == 0.6)
    }
}

@Test func aLevelReadGivesWayToAWaitingChange() async {
    let worker = DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: DroppingChannel(), allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true })
    let session = worker.fence.snapshot()
    _ = await worker.scan([deskScreen], session: session)
    worker.fence.setWriteWaiting(true)
    #expect(await worker.refresh(ids: ["lg"], session: session) == nil)
    worker.fence.setWriteWaiting(false)
    #expect(await worker.refresh(ids: ["lg"], session: session)?.first?.brightness == 0.4)
}

/// Drops the first two brightness requests, as a panel can while it wakes.
private final class DroppingChannel: DDCChannel, Sendable {
    let brightnessRequests = OSAllocatedUnfairLock(initialState: 0)

    func read(_ feature: Feature) -> [UInt8]? {
        if feature == .brightness, brightnessRequests.withLock({ $0 += 1; return $0 }) <= 2 { return nil }
        let bytes: [UInt8] = [0x6e, 0x88, 2, 0, feature.rawValue, 0, 0, 100, 0, feature == .mute ? 2 : 40]
        return bytes + [bytes.reduce(UInt8(0x50), ^)]
    }

    func write(_ feature: Feature, value: UInt16) -> Bool { true }
}

@Test func aThirdReadRecoversAControlAfterTwoDroppedRequests() async {
    let channel = DroppingChannel()
    let worker = DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "lg", screenID: 42, name: "LG", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: channel, allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true })
    let displays = await worker.scan([deskScreen], session: worker.fence.snapshot())
    #expect(displays.first?.brightness == 0.4)
    #expect(channel.brightnessRequests.withLock { $0 } == 3)
}

/// Answers like a Dell S3425DW: the volume works, and the mute register
/// reports one fixed value whatever is written to it.
private final class StuckMuteChannel: DDCChannel, Sendable {
    struct State {
        var volume: UInt16 = 45
        var muteWrites: [UInt16] = []
        var volumeWrites: [UInt16] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let reported: UInt8
    let holds: Bool
    init(reported: UInt8, holds: Bool = false) {
        self.reported = reported
        self.holds = holds
    }

    func read(_ feature: Feature) -> [UInt8]? {
        let (volume, lastMute) = state.withLock { ($0.volume, $0.muteWrites.last) }
        let current: UInt8 = switch feature {
        case .brightness: 59
        case .volume: UInt8(volume)
        case .mute: holds ? UInt8(lastMute ?? UInt16(reported)) : reported
        }
        let bytes: [UInt8] = [0x6e, 0x88, 2, 0, feature.rawValue, 0, 0, feature == .mute ? 2 : 100, 0, current]
        return bytes + [bytes.reduce(UInt8(0x50), ^)]
    }

    func write(_ feature: Feature, value: UInt16) -> Bool {
        state.withLock {
            if feature == .mute { $0.muteWrites.append(value) }
            if feature == .volume {
                $0.volume = value
                $0.volumeWrites.append(value)
            }
        }
        return true
    }
}

private func muteWorker(_ channel: StuckMuteChannel, memory: MuteMemory = MuteMemory()) -> DisplayWorker {
    DisplayWorker(discover: { _ in
        let display = MonitorDisplay(id: "dell", screenID: 42, name: "DELL", brightness: nil, volume: nil, muted: nil)
        return [Endpoint(display: display, channel: channel, allowsLGQuirk: false, appleBrightness: false)]
    }, isOnline: { _ in true }, memory: memory)
}

@MainActor @Test func aMuteRegisterStuckOnMutedIsReplacedByVolumeZero() async {
    let channel = StuckMuteChannel(reported: 1)
    let saved = OSAllocatedUnfairLock(initialState: [String: Int]())
    let memory = MuteMemory(load: { [:] }, save: { value in saved.withLock { $0 = value } })
    let controller = DisplayController(worker: muteWorker(channel, memory: memory)) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    // The monitor says "muted" and plays at 45.
    #expect(controller.displays.first?.muted == false)
    #expect(controller.displays.first?.mutesByVolume == true)
    #expect(saved.withLock { $0 } == ["dell": 1])

    controller.setMuted(true, for: "dell")
    await controller.waitUntilIdle()
    #expect(channel.state.withLock { $0.volume } == 0)
    #expect(controller.displays.first?.muted == true)
    #expect(controller.displays.first?.volume == 0)

    controller.setMuted(false, for: "dell")
    await controller.waitUntilIdle()
    #expect(channel.state.withLock { $0.volume } == 45)
    #expect(controller.displays.first?.muted == false)
    #expect(controller.displays.first?.volume == 0.45)

    // Raising the volume from zero is an unmute as well.
    controller.setVolume(0, for: "dell")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.muted == true)
    controller.setVolume(0.2, for: "dell")
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.muted == false)
    #expect(controller.lastError == nil)
}

@Test func aWorkingMuteIsPutBackAfterTheCheckAndNotCheckedAgain() async {
    let channel = StuckMuteChannel(reported: 1, holds: true)
    let saved = OSAllocatedUnfairLock(initialState: [String: Int]())
    let memory = MuteMemory(load: { saved.withLock { $0 } }, save: { value in saved.withLock { $0 = value } })
    let worker = muteWorker(channel, memory: memory)
    let displays = await worker.scan([deskScreen], session: worker.fence.snapshot())
    #expect(displays.first?.muted == true)
    #expect(displays.first?.mutesByVolume == false)
    #expect(channel.state.withLock { $0.muteWrites } == [2, 2, 1, 1])

    let again = await muteWorker(channel, memory: memory).scan([deskScreen], session: worker.fence.snapshot())
    #expect(again.first?.muted == true)
    #expect(channel.state.withLock { $0.muteWrites.count } == 4)
}

@MainActor @Test func aMuteStuckOnUnmutedIsFoundOnTheFirstPress() async {
    let channel = StuckMuteChannel(reported: 2)
    let controller = DisplayController(worker: muteWorker(channel)) { [deskScreen] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    #expect(controller.displays.first?.mutesByVolume == false)

    controller.setMuted(true, for: "dell")
    await controller.waitUntilIdle()
    #expect(channel.state.withLock { $0.volume } == 0)
    #expect(controller.displays.first?.muted == true)
    #expect(controller.displays.first?.mutesByVolume == true)
    #expect(controller.lastError == nil)
}
