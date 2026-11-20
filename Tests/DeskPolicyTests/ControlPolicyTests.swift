import Foundation
import Testing
import DeskPolicy

@Test func exactNamesPreserveModelNumbersAndNeedUniqueEndpoints() {
    let screens = [DisplayCandidate(id: "left", name: "  LG   28 "), .init(id: "right", name: "LG 29")]
    #expect(OutputPairing.resolve(outputName: "lg 28", connectedDisplayOutputNames: ["LG 28","LG 29"], monitors: screens, preferredID: nil) == "left")
    #expect(OutputPairing.resolve(outputName: "LG", connectedDisplayOutputNames: ["LG"], monitors: screens, preferredID: nil) == nil)
    #expect(OutputPairing.resolve(outputName: "LG 28", connectedDisplayOutputNames: ["LG 28","LG 28"], monitors: screens, preferredID: nil) == nil)
}
@Test func ambiguousOrMissingDisplayRequiresChoice() {
    let both = [DisplayCandidate(id: "a", name: "LG"), .init(id: "b", name: "LG")]
    #expect(OutputPairing.resolve(outputName: "LG", connectedDisplayOutputNames: ["LG"], monitors: both, preferredID: nil) == nil)
    #expect(OutputPairing.resolve(outputName: "LG", connectedDisplayOutputNames: ["LG"], monitors: both, preferredID: "a") == "a")
    #expect(OutputPairing.resolve(outputName: "LG", connectedDisplayOutputNames: ["LG"], monitors: [both[1]], preferredID: "a") == nil)
}
@Test func heldKeyCannotReachNewDeviceAndKeyUpIsPaired() throws {
    var tracker = PressTracker()
    let down = try #require(MediaPress(data: 0x00000a00))
    let repeated = try #require(MediaPress(data: 0x00000a01))
    let up = try #require(MediaPress(data: 0x00000b00))
    #expect(tracker.disposition(for: down, target: .monitor("LG")) == .adjust("LG"))
    #expect(tracker.disposition(for: repeated, target: .monitor("LG")) == .adjust("LG"))
    #expect(tracker.disposition(for: repeated, target: .monitor("Dell")) == .consume)
    #expect(tracker.disposition(for: repeated, target: .monitor("LG")) == .consume)
    #expect(tracker.disposition(for: up, target: .system) == .consume)
    #expect(tracker.disposition(for: down, target: .system) == .passThrough)
    #expect(tracker.disposition(for: repeated, target: .monitor("LG")) == .passThrough)
    #expect(tracker.disposition(for: up, target: .monitor("LG")) == .passThrough)
}

@Test func cancellingSpeakerAdjustmentsLeavesBrightnessHeld() throws {
    var tracker = PressTracker()
    let volumeDown = try #require(MediaPress(data: 0x00010a00))
    let volumeRepeat = try #require(MediaPress(data: 0x00010a01))
    let volumeUp = try #require(MediaPress(data: 0x00010b00))
    let brightnessDown = try #require(MediaPress(data: 0x00030a00))
    let brightnessRepeat = try #require(MediaPress(data: 0x00030a01))
    let monitor = KeyTarget.monitor("LG")
    #expect(tracker.disposition(for: volumeDown, target: monitor) == .adjust("LG"))
    #expect(tracker.disposition(for: brightnessDown, target: monitor) == .adjust("LG"))
    tracker.cancelAdjustments(audioOnly: true)
    #expect(tracker.disposition(for: volumeRepeat, target: monitor) == .consume)
    #expect(tracker.disposition(for: brightnessRepeat, target: monitor) == .adjust("LG"))
    tracker.cancelAdjustments()
    #expect(tracker.disposition(for: brightnessRepeat, target: monitor) == .consume)
    #expect(tracker.disposition(for: volumeUp, target: .system) == .consume)
    #expect(tracker.disposition(for: volumeDown, target: monitor) == .adjust("LG"))
}
@Test func muteRepeatsAndUnrelatedKeys() throws {
    var tracker = PressTracker()
    #expect(MediaPress(data: 0x100a00) == nil)
    #expect(MediaPress(data: 0x070300) == nil)
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x070a00)), target: .monitor("LG")) == .adjust("LG"))
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x070a01)), target: .monitor("LG")) == .consume)
}

@Test func brightnessTargetsThePointerAcrossThreeArrangedScreens() {
    let screens = [DisplayPlacement(screenID: 7, frame: CGRect(x: 0, y: 0, width: 1500, height: 900)),
                   DisplayPlacement(screenID: 18, frame: CGRect(x: -1200, y: 75, width: 1200, height: 980)),
                   DisplayPlacement(screenID: 23, frame: CGRect(x: 0, y: 900, width: 1500, height: 800))]
    #expect(DisplayPlacement.atPointer(CGPoint(x: -42, y: 600), screens: screens) == 18)
    #expect(DisplayPlacement.atPointer(CGPoint(x: 400, y: 950), screens: screens) == 23)
    #expect(DisplayPlacement.atPointer(CGPoint(x: 0, y: 250), screens: screens) == 7)
    #expect(DisplayPlacement.atPointer(CGPoint(x: -5, y: -30), screens: screens) == nil)
}

@Test func pointerOnTheTopPixelRowStaysOnItsOwnScreen() {
    let lower = DisplayPlacement(screenID: 7, frame: CGRect(x: 0, y: 0, width: 1500, height: 900))
    let upper = DisplayPlacement(screenID: 23, frame: CGRect(x: 0, y: 900, width: 1500, height: 800))
    // NSEvent.mouseLocation reports y == frame.maxY on the top row.
    #expect(DisplayPlacement.atPointer(CGPoint(x: 400, y: 900), screens: [lower]) == 7)
    #expect(DisplayPlacement.atPointer(CGPoint(x: 400, y: 900), screens: [upper, lower]) == 7)
    #expect(DisplayPlacement.atPointer(CGPoint(x: 400, y: 1700), screens: [upper, lower]) == 23)
    #expect(DisplayPlacement.atPointer(CGPoint(x: 400, y: 900.5), screens: [upper, lower]) == 23)
}

@Test func pointingAtAnUnsupportedMonitorDoesNotDimTheMacBook() throws {
    let external = KeyTarget.brightness(external: true, controllableID: nil)
    let builtin = KeyTarget.brightness(external: false, controllableID: nil)
    var tracker = PressTracker()
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x030a00)), target: external) == .consume)
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x030a01)), target: builtin) == .consume)
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x030b00)), target: builtin) == .consume)
    #expect(tracker.disposition(for: try #require(MediaPress(data: 0x030a00)), target: builtin) == .passThrough)
}
