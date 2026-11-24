import Foundation
import Testing
@testable import AudioRouting

private func mic(_ id: String, connected: Bool = true, hidden: Bool = false) -> RouteDevice {
    RouteDevice(id: id, uid: id, name: id, role: .input, isDisplay: false, isHidden: hidden, isConnected: connected, isVirtual: false)
}

private let usb = mic("usb"), builtin = mic("builtin"), pods = mic("pods")
private let docked = [usb, builtin]
private let undocked = [mic("usb", connected: false), builtin]
private let order: Set<String> = ["usb", "builtin"]

@Test func theTopMicrophoneReturnsAfterAHandPickedOneWasUnplugged() {
    var policy = RoutePolicy()
    _ = policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 0)
    policy.didSelect(usb, manually: true, replacing: builtin, time: 1)
    #expect(policy.desired(current: usb, devices: docked, rankedIDs: order, time: 2) == usb)

    // Unplugged: macOS falls back to the built-in microphone.
    #expect(policy.desired(current: builtin, devices: undocked, rankedIDs: order, time: 100) == builtin)
    #expect(policy.heldID == nil)

    // Plugged in again: macOS leaves the built-in microphone selected.
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 200) == usb)
}

@Test func aHandPickedLowerMicrophoneLastsUntilAHigherOneConnects() {
    var policy = RoutePolicy()
    _ = policy.desired(current: usb, devices: docked, rankedIDs: order, time: 0)
    policy.didSelect(builtin, manually: true, replacing: usb, time: 1)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 2) == builtin)
    // It stays while nothing connects, however often the devices are read.
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 50) == builtin)
    #expect(policy.heldID == builtin.id)

    #expect(policy.desired(current: builtin, devices: undocked, rankedIDs: order, time: 100) == builtin)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 200) == usb)
    #expect(policy.heldID == nil)
}

@Test func aLowerOrUnlistedArrivalDoesNotEndAHandPick() {
    var policy = RoutePolicy()
    let ranked: Set<String> = ["usb", "builtin", "headset"]
    let headset = mic("headset")
    _ = policy.desired(current: usb, devices: [usb, builtin], rankedIDs: ranked, time: 0)
    policy.didSelect(builtin, manually: true, replacing: usb, time: 1)
    _ = policy.desired(current: builtin, devices: [usb, builtin], rankedIDs: ranked, time: 2)
    #expect(policy.desired(current: builtin, devices: [usb, builtin, headset], rankedIDs: ranked, time: 100) == builtin)
    #expect(policy.desired(current: builtin, devices: [usb, builtin, headset, pods], rankedIDs: ranked, time: 200) == builtin)
    #expect(policy.heldID == builtin.id)
}

@Test func aFallbackSeenBeforeTheUnplugIsNotKeptAsAHandPick() {
    var policy = RoutePolicy()
    _ = policy.desired(current: usb, devices: docked, rankedIDs: order, time: 0)
    // macOS moves the default a moment before the unplugged device leaves the list.
    _ = policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 100)
    _ = policy.desired(current: builtin, devices: undocked, rankedIDs: order, time: 100.1)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 200) == usb)
}

@Test func aDefaultMovedWhileDevicesAreArrivingIsNotAHandPick() {
    var policy = RoutePolicy()
    let display = mic("display")
    _ = policy.desired(current: builtin, devices: undocked, rankedIDs: order, time: 0)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 100) == usb)
    policy.didSelect(usb, manually: false, replacing: builtin, time: 100)
    #expect(policy.desired(current: usb, devices: docked, rankedIDs: order, time: 100.2) == usb)
    // A second device from the same dock arrives and macOS moves the default back.
    #expect(policy.desired(current: builtin, devices: docked + [display], rankedIDs: order, time: 102) == usb)
    #expect(policy.heldID == nil)
}

@Test func aSavedHandPickSurvivesARelaunchUntilAHigherMicrophoneConnects() {
    var policy = RoutePolicy(heldID: builtin.id, passedOver: [usb.id, builtin.id])
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 0) == builtin)
    #expect(policy.heldID == builtin.id)

    // Saved while undocked, relaunched after docking.
    var later = RoutePolicy(heldID: builtin.id, passedOver: [builtin.id])
    #expect(later.desired(current: builtin, devices: docked, rankedIDs: order, time: 0) == usb)
    #expect(later.heldID == nil)
}

@Test func aHoldSavedByAnOlderBuildGivesWayToAHigherConnectedMicrophone() throws {
    let saved = Data(#"{"inputOrder":["usb","builtin"],"inputHold":"builtin"}"#.utf8)
    let preferences = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    var policy = RoutePolicy(heldID: preferences.inputHold, passedOver: preferences.inputPassedOver)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 0) == usb)
}

@Test func theDevicesSeenWithAHandPickAreSaved() throws {
    var preferences = RoutePreferences()
    preferences.inputHold = "builtin"
    preferences.inputPassedOver = ["usb", "builtin"]
    preferences.inputHoldMadeHere = true
    let copy = try JSONDecoder().decode(RoutePreferences.self, from: JSONEncoder().encode(preferences))
    #expect(copy == preferences)
    let damaged = Data(#"{"inputHold":"builtin","inputHoldMadeHere":true,"inputPassedOver":["usb",7],"outputPassedOver":false}"#.utf8)
    let read = try JSONDecoder().decode(RoutePreferences.self, from: damaged)
    #expect(read.inputPassedOver == ["usb"])
    #expect(read.outputPassedOver.isEmpty)
}

/// The identifiers from a real dock that moved a serial-less USB microphone to another port.
@Test func theTopMicrophoneIsRecognisedOnADifferentPort() throws {
    let family = "AppleUSBAudioEngine:GeneralPlus:USB Audio Device"
    func endpoints(port: String?) -> [Endpoint] {
        var list = [Endpoint(objectID: 94, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", role: .input)]
        if let port {
            list.append(Endpoint(objectID: 7656, uid: "\(family):\(port):2", name: "USB Audio Device", role: .input, followsPort: true))
        }
        return list
    }
    var preferences = RoutePreferences()
    preferences.remember(endpoints(port: "114000"))
    preferences.inputOrder = ["\(family):114000:2", "BuiltInMicrophoneDevice"]
    var policy = RoutePolicy()
    func step(port: String?, current uid: String, time: TimeInterval) -> RouteDevice? {
        preferences.remember(endpoints(port: port))
        let rows = preferences.devices(endpoints(port: port), role: .input)
        return policy.desired(current: rows.first { $0.uid == uid && $0.isConnected }, devices: rows,
                              rankedIDs: Set(rows.map(\.id)), time: time)
    }
    let first = try #require(step(port: "114000", current: "BuiltInMicrophoneDevice", time: 0))
    policy.didSelect(first, manually: true, time: 1)
    #expect(step(port: "114000", current: first.uid, time: 2)?.id == first.id)
    #expect(step(port: nil, current: "BuiltInMicrophoneDevice", time: 100)?.uid == "BuiltInMicrophoneDevice")
    let returned = try #require(step(port: "1114000", current: "BuiltInMicrophoneDevice", time: 200))
    #expect(returned.id == first.id)
    #expect(returned.uid == "\(family):1114000:2")
}

@Test func aMicrophoneMovedOutsideTheAppGoesBackToTheTopOfTheList() {
    // The headset was already connected when macOS moved the microphone to it.
    let all = [usb, builtin, pods]
    let ranked: Set<String> = ["usb", "builtin", "pods"]
    var policy = RoutePolicy(followsOutsidePicks: false)
    #expect(policy.desired(current: usb, devices: all, rankedIDs: ranked, time: 0) == usb)
    #expect(policy.desired(current: pods, devices: all, rankedIDs: ranked, time: 100) == usb)
    #expect(policy.heldID == nil)

    // The same move of an output is still a pick by hand.
    var output = RoutePolicy()
    _ = output.desired(current: usb, devices: all, rankedIDs: ranked, time: 0)
    #expect(output.desired(current: pods, devices: all, rankedIDs: ranked, time: 100) == pods)
}

@Test func aMicrophonePickedInTheAppSurvivesAMoveMadeOutsideIt() {
    let all = [usb, builtin, pods]
    let ranked: Set<String> = ["usb", "builtin", "pods"]
    var policy = RoutePolicy(followsOutsidePicks: false)
    _ = policy.desired(current: usb, devices: all, rankedIDs: ranked, time: 0)
    policy.didSelect(builtin, manually: true, replacing: usb, time: 1)
    #expect(policy.desired(current: builtin, devices: all, rankedIDs: ranked, time: 2) == builtin)
    #expect(policy.desired(current: pods, devices: all, rankedIDs: ranked, time: 100) == builtin)
    #expect(policy.heldID == builtin.id)
}

@Test func aMicrophoneChosenWhileTheAppWasClosedDoesNotReplaceTheList() {
    var policy = RoutePolicy(followsOutsidePicks: false)
    #expect(policy.desired(current: builtin, devices: docked, rankedIDs: order, time: 0) == usb)
    #expect(policy.heldID == nil)
}

@Test func aMicrophoneHoldSavedBeforeOutsidePicksStoppedCountingIsDropped() throws {
    let saved = Data(#"{"inputHold":"pods","inputPassedOver":["usb","pods"],"outputHold":"speakers"}"#.utf8)
    let preferences = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    #expect(preferences.inputHold == nil)
    #expect(preferences.inputPassedOver.isEmpty)
    #expect(preferences.outputHold == "speakers")
}
