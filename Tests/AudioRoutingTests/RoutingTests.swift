import Foundation
import Testing
@testable import AudioRouting

private func microphone(_ uid: String, port: Bool? = false, objectID: UInt32 = 1) -> Endpoint {
    Endpoint(objectID: objectID, uid: uid, name: "USB Audio Device", role: .input, followsPort: port)
}

private func audio(_ uid: String, role: RouteRole = .input, connected: Bool = true) -> RouteDevice {
    RouteDevice(id: uid, uid: uid, name: uid, role: role, isDisplay: false, isHidden: false, isConnected: connected, isVirtual: false)
}

private let usbA = "AppleUSBAudioEngine:Acme:Mic:01100000:1"
private let usbB = "AppleUSBAudioEngine:Acme:Mic:02300000:1"

@Test func confirmedPortReconnectPreservesVisibilityAndRank() throws {
    var settings = RoutePreferences()
    let a = microphone(usbA, port: true)
    let b = microphone(usbB, port: true)
    let builtin = microphone("builtin")
    settings.remember([a, builtin])
    let original = try #require(settings.devices([a, builtin], role: .input).first { $0.uid == usbA })
    settings.setHidden(true, device: original)
    settings.inputOrder = [usbA, "builtin"]
    settings.remember([b, builtin])
    let rows = settings.devices([b, builtin], role: .input)
    #expect(rows.count == 2)
    #expect(rows.first?.id == original.id)
    #expect(rows.first?.uid == usbB)
    #expect(rows.first?.isHidden == true)
    #expect(settings.rankedIDs(for: .input).contains(try #require(rows.first).id))
}

@Test func simultaneousSiblingsRestoreIndependentIdentities() throws {
    var settings = RoutePreferences()
    let a = microphone(usbA, port: true)
    let b = microphone(usbB, port: true)
    settings.remember([a])
    settings.setHidden(true, device: try #require(settings.devices([a], role: .input).first))
    settings.remember([b])
    settings.remember([a, b])
    let both = settings.devices([a, b], role: .input)
    #expect(Set(both.map(\.id)).count == 2)
    #expect(both.first { $0.uid == usbA }?.isHidden == true)
    #expect(both.first { $0.uid == usbB }?.isHidden == false)
    settings.remember([b])
    #expect(settings.devices([b], role: .input).count == 2)
}

@Test func hexadecimalSerialAndUnverifiedLocationsStaySeparate() {
    var settings = RoutePreferences()
    let a = microphone(usbA, port: nil)
    let b = microphone(usbB, port: false)
    settings.remember([a])
    settings.remember([b])
    #expect(settings.devices([b], role: .input).count == 2)
}

@Test func independentDisplayPortsKeepOneRecoveredRowUntilBothAppear() throws {
    var settings = RoutePreferences()
    func display(_ uid: String) -> Endpoint {
        Endpoint(objectID: 3, uid: uid, name: "LG", role: .output, isDisplay: true, followsPort: true)
    }
    let uuid = "70993403-A8A4-4900-ABCF-4BB8CBA41D34"
    let a = display(uuid)
    let b = display(uuid + "_02000000")
    settings.remember([a])
    settings.outputOrder = [a.uid]
    let id = try #require(settings.devices([a], role: .output).first?.id)
    settings.remember([b])
    #expect(settings.devices([b], role: .output).map(\.id) == [id])
    settings.remember([a, b])
    #expect(settings.devices([a, b], role: .output).count == 2)
}

@Test func externalChoiceOfConnectedAirPodsLastsUntilDisconnect() {
    let usb = audio("usb"), pods = audio("pods"), builtin = audio("builtin")
    var policy = RoutePolicy()
    let devices = [usb, pods, builtin]
    #expect(policy.desired(current: usb, devices: devices, rankedIDs: [usb.id], time: 1) == usb)
    #expect(policy.desired(current: pods, devices: devices, rankedIDs: [usb.id], time: 2) == pods)
    #expect(policy.heldID == pods.id)
    #expect(policy.desired(current: pods, devices: devices + [audio("another")], rankedIDs: [usb.id], time: 3) == pods)
    #expect(policy.desired(current: builtin, devices: [usb, builtin], rankedIDs: [usb.id], time: 4) == builtin)
    #expect(policy.heldID == builtin.id)
    #expect(policy.desired(current: pods, devices: devices, rankedIDs: [usb.id], time: 5) == builtin)
}

@Test func physicalReconnectDoesNotStealHeldMicrophone() {
    let usb = audio("usb"), pods = audio("pods")
    var policy = RoutePolicy()
    policy.didSelect(usb, manually: true)
    _ = policy.desired(current: usb, devices: [usb], rankedIDs: [], time: 1)
    _ = policy.desired(current: usb, devices: [pods, usb], rankedIDs: [], time: 2)
    #expect(policy.desired(current: pods, devices: [pods, usb], rankedIDs: [], time: 3) == usb)
    #expect(policy.heldID == usb.id)
}

@Test func outputReturnsToExistingMonitorWithoutMutingOrCopyingHeadphoneLevel() {
    let lg = audio("lg", role: .output), pods = audio("pods", role: .output)
    var policy = RoutePolicy()
    _ = policy.desired(current: lg, devices: [lg, pods], rankedIDs: [], time: 0)
    policy.didSelect(pods, manually: true)
    #expect(policy.desired(current: lg, devices: [lg], rankedIDs: [], time: 3) == lg)
    #expect(policy.heldID == nil)
}

@Test func preferenceImportIsExplicitAndIdempotent() throws {
    var settings = RoutePreferences()
    let data = try JSONSerialization.data(withJSONObject: [["uid": "mic", "name": "Saved mic", "isInput": true]])
    let source: [String: Any] = ["knownDevices": data, "inputPriorities": ["mic", "builtin"], "hiddenMics": ["mic"],
                                 "headphonePriorities": ["airpods"], "speakerPriorities": ["lg", "lg"]]
    settings.inputOrder = ["new-device", "mic"]
    let didImport = settings.importLegacy(source)
    #expect(didImport)
    #expect(settings.inputOrder == ["mic", "builtin", "new-device"])
    #expect(settings.outputOrder == ["airpods", "lg"])
    let mic = try #require(settings.devices([], role: .input).first { $0.uid == "mic" })
    #expect(mic.name == "Saved mic")
    #expect(mic.isHidden && !mic.isConnected)
    let repeated = settings.importLegacy(source)
    #expect(!repeated)
}

@Test func manualSelectionWhileStoppedIsPreservedOnRestart() {
    let usb = audio("usb"), pods = audio("pods")
    var policy = RoutePolicy(heldID: usb.id)
    #expect(policy.desired(current: pods, devices: [usb, pods], rankedIDs: [usb.id], time: 1) == pods)
    #expect(policy.heldID == pods.id)
}

@Test func reorderIncludesDisconnectedRankAndVisibilityAffectsEligibility() throws {
    var settings = RoutePreferences()
    let a = microphone("a"), b = microphone("b"), c = microphone("c")
    settings.remember([a, b, c])
    settings.inputOrder = ["a", "b", "c"]
    let before = settings.devices([a, c], role: .input)
    let rowC = try #require(before.first { $0.uid == "c" })
    let moved = settings.move(rowC, by: -1, in: before)
    #expect(moved)
    #expect(settings.inputOrder == ["a", "c", "b"])
    settings.setHidden(true, device: try #require(before.first { $0.uid == "a" }))
    let after = settings.devices([a, c], role: .input)
    var policy = RoutePolicy()
    #expect(policy.desired(current: after.first, devices: after, rankedIDs: Set(after.map(\.id)), time: 1)?.uid == "c")
}

@Test func hidingActiveDeviceWithoutRanksSelectsVisiblePhysicalAlternative() {
    let hidden = RouteDevice(id: "old", uid: "old", name: "Old", role: .output, isDisplay: false, isHidden: true, isConnected: true, isVirtual: false)
    let virtual = RouteDevice(id: "app", uid: "app", name: "App", role: .output, isDisplay: false, isHidden: false, isConnected: true, isVirtual: true)
    let visible = audio("desk", role: .output)
    var policy = RoutePolicy()
    #expect(policy.desired(current: hidden, devices: [hidden, virtual, visible], rankedIDs: [], time: 1) == visible)
    #expect(policy.desired(current: hidden, devices: [hidden], rankedIDs: [], time: 2) == hidden)
}

@Test func fallbackInputHoldSurvivesEmptyIntermediateInventory() {
    let usb = audio("usb"), pods = audio("pods")
    var policy = RoutePolicy()
    _ = policy.desired(current: pods, devices: [usb, pods], rankedIDs: [], time: 1)
    policy.didSelect(pods, manually: true)
    #expect(policy.desired(current: nil, devices: [], rankedIDs: [], time: 2) == nil)
    #expect(policy.desired(current: usb, devices: [usb], rankedIDs: [], time: 3) == usb)
    #expect(policy.heldID == usb.id)
    #expect(policy.desired(current: pods, devices: [usb, pods], rankedIDs: [], time: 4) == usb)
}

@Test func initialEmptyHALInventoryDoesNotEraseSavedInputChoice() {
    let usb = audio("usb")
    var policy = RoutePolicy(heldID: usb.id)
    #expect(policy.desired(current: nil, devices: [], rankedIDs: [], time: 0) == nil)
    #expect(policy.heldID == usb.id)
    #expect(policy.desired(current: usb, devices: [usb], rankedIDs: [], time: 1) == usb)
}

@Test func importedVisibilityFollowsCanonicalRecordForAllPreviousPorts() throws {
    var settings = RoutePreferences()
    let data = try JSONSerialization.data(withJSONObject: [["uid": usbA, "name": "USB mic", "isInput": true,
                                                            "followsPortChanges": true, "previousUIDs": [usbB]]])
    let imported = settings.importLegacy(["hiddenMics": [usbA], "knownDevices": data])
    #expect(imported)
    let moved = microphone(usbB, port: true)
    settings.remember([moved])
    let items = settings.devices([moved], role: .input)
    #expect(items.count == 1)
    #expect(items.first?.isHidden == true)
}

@Test func startupWaitsForMacOSToPublishTheCurrentMicrophone() {
    let usb = audio("usb"), pods = audio("pods")
    var policy = RoutePolicy(heldID: usb.id)
    let connected = [usb, pods]
    _ = policy.desired(current: nil, devices: connected, rankedIDs: [usb.id], time: 0)
    #expect(policy.desired(current: pods, devices: connected, rankedIDs: [usb.id], time: 1) == pods)
    #expect(policy.heldID == pods.id)
}

@Test func restartingAfterHeldMicrophoneDisconnectedKeepsTheMacOSFallback() {
    let usb = audio("usb"), pods = audio("pods"), builtin = audio("builtin")
    var input = RoutePolicy(heldID: pods.id)
    #expect(input.desired(current: builtin, devices: [usb, builtin], rankedIDs: [usb.id], time: 0) == builtin)
    #expect(input.desired(current: pods, devices: [usb, builtin, pods], rankedIDs: [usb.id], time: 1) == builtin)
    #expect(input.heldID == builtin.id)

    let display = audio("display", role: .output), speakers = audio("speakers", role: .output)
    var output = RoutePolicy(heldID: "disconnected-headphones")
    #expect(output.desired(current: speakers, devices: [display, speakers], rankedIDs: [display.id], time: 0) == display)
    #expect(output.heldID == nil)
}
