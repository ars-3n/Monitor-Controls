import DisplayHardware
import XCTest

/// An explicit desk test. Routine test runs use fixtures and never write to hardware.
final class LGHardwareTests: XCTestCase {
    @MainActor func testLGReadChangeAndRestore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESK_CONTROLS_TEST_LG"] == "1")
        let controller = DisplayController()
        controller.start()
        defer { controller.stop() }
        await controller.waitUntilIdle()
        let matches = controller.displays.filter { $0.name.caseInsensitiveCompare("LG ULTRAWIDE") == .orderedSame }
        XCTAssertEqual(matches.count, 1, "Connect exactly one LG ULTRAWIDE for this test.")
        guard matches.count == 1 else { return }
        let screen = matches[0]
        let brightness = try XCTUnwrap(screen.brightness)
        let volume = try XCTUnwrap(screen.volume)
        let originalMute = try XCTUnwrap(screen.muted)
        // All potentially throwing preconditions precede the first write.
        func read() async -> MonitorDisplay? {
            await controller.waitUntilIdle()
            controller.refreshValues()
            await controller.waitUntilIdle()
            return controller.displays.first { $0.id == screen.id && $0.screenID == screen.screenID }
        }
        func oneStep(_ value: Double) -> Double { value >= 0.02 ? value - 0.01 : value + 0.01 }
        controller.setBrightness(oneStep(brightness), for: screen.id)
        let dimmer = await read()
        XCTAssertEqual(dimmer?.brightness ?? -1, oneStep(brightness), accuracy: 0.001)
        controller.setBrightness(brightness, for: screen.id)
        let restoredBrightness = await read()
        XCTAssertEqual(restoredBrightness?.brightness ?? -1, brightness, accuracy: 0.001)

        // A few speakers round an intermediate 1% request to the existing level.
        let quieterTarget = volume >= 0.02 ? volume - 0.02 : volume + 0.02
        controller.setVolume(quieterTarget, for: screen.id)
        let quieter = await read()
        XCTAssertEqual(quieter?.volume ?? -1, quieterTarget, accuracy: 0.001)
        controller.setVolume(volume, for: screen.id)
        let restoredVolume = await read()
        XCTAssertEqual(restoredVolume?.volume ?? -1, volume, accuracy: 0.001)

        // A previously muted system should never be unmuted during this check.
        if !originalMute {
            controller.setMuted(true, for: screen.id)
            let muted = await read()
            XCTAssertEqual(muted?.muted, true)
            controller.setMuted(false, for: screen.id)
        }
        let final = await read()
        XCTAssertEqual(final?.muted, originalMute)
        XCTAssertEqual(final?.brightness ?? -1, brightness, accuracy: 0.001)
        XCTAssertEqual(final?.volume ?? -1, volume, accuracy: 0.001)
        print("LG hardware check: brightness \(brightness), volume \(volume), muted \(originalMute); final \(String(describing: final?.brightness)), \(String(describing: final?.volume)), \(String(describing: final?.muted))")
    }
}
