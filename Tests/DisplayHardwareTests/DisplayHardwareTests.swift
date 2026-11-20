import CoreGraphics
import Testing
@testable import DisplayHardware

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

    func scan(_ screens: [ScreenDescription], session: Session) -> [MonitorDisplay] { [display] }
    func refresh(ids: [String], session: Session) -> [MonitorDisplay] { [display] }
    func write(_ key: ControlKey, fraction: Double, session: Session) -> WriteResult {
        sent.append(key)
        display.apply(fraction, to: key.feature)
        return WriteResult(value: fraction, success: true)
    }
}

@MainActor @Test func rapidSlidersCoalesceAndRouteChangesDropPendingSpeakerWrites() async {
    let worker = TestDisplayIO()
    let controller = DisplayController(worker: worker) { [] }
    controller.start()
    defer { controller.stop() }
    await controller.waitUntilIdle()
    for value in 1...100 { controller.setBrightness(Double(value)/100, for: "lg") }
    controller.setVolume(0.55, for: "lg")
    controller.setMuted(true, for: "lg")
    controller.cancelPendingAudioWrites()
    await controller.waitUntilIdle()
    #expect(await worker.sent == [ControlKey(id: "lg", feature: .brightness)])
    #expect(controller.displays.first?.brightness == 1)
    #expect(controller.displays.first?.volume == 0.18)
    #expect(controller.displays.first?.muted == false)
}
