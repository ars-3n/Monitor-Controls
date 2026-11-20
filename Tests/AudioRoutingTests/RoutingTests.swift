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

@Test func usbIdentityUsesLocationAndSerialDescriptorsWhenVendorNamesAreMissing() {
    let uid = "AppleUSBAudioEngine:Unknown Manufacturer:Jabra Link 380:00114000:1,2"
    func classify(_ descriptor: (Int?, String?)?, serialExists: Bool = false) -> Bool? {
        CoreAudioProperties.isSeriallessUSBDevice(uid: uid, at: 0x00114000, hasSerial: { candidate in
            #expect(candidate == "00114000")
            return serialExists
        }, descriptorAt: { location in
            #expect(location == 0x00114000)
            return descriptor
        })
    }
    #expect(classify((0, nil)) == true)
    #expect(classify((0, "")) == true)
    #expect(classify((3, nil)) == false)
    #expect(classify((nil, "serial")) == false)
    #expect(classify((0, "00114000")) == false)
    #expect(classify((0, nil), serialExists: true) == false)
    #expect(classify((nil, nil)) == nil)
    #expect(classify(nil) == nil)
}

@Test func genericHDMIOutputsKeepSeparatePrioritiesAndVisibility() throws {
    let zero = "00000000-0000-0000-0000-000000000000"
    let old = Endpoint(objectID: 1, uid: zero, name: "HDMI Audio", role: .output, isDisplay: true, followsPort: true)
    let new = Endpoint(objectID: 2, uid: zero + "_00000020", name: "HDMI Audio", role: .output, isDisplay: true, followsPort: true)
    var settings = RoutePreferences()
    settings.remember([old])
    settings.outputOrder = [old.uid]
    settings.setHidden(true, device: try #require(settings.devices([old], role: .output).first))
    settings.remember([new])
    let rows = settings.devices([new], role: .output)
    #expect(rows.count == 2)
    let current = try #require(rows.first { $0.isConnected })
    #expect(!current.isHidden)
    #expect(!settings.rankedIDs(for: .output).contains(current.id))
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

@Test func reorderStepsOverHiddenDevices() throws {
    var settings = RoutePreferences()
    let a = microphone("a"), b = microphone("b"), c = microphone("c")
    settings.remember([a, b, c])
    settings.inputOrder = ["a", "b", "c"]
    settings.setHidden(true, device: try #require(settings.devices([a, b, c], role: .input).first { $0.uid == "b" }))

    var rows = settings.devices([a, b, c], role: .input)
    let step1 = settings.move(try #require(rows.last), by: -1, in: rows)
    #expect(step1)
    #expect(settings.inputOrder == ["c", "a", "b"])

    rows = settings.devices([a, b, c], role: .input)
    let step2 = settings.move(try #require(rows.first), by: 1, in: rows)
    #expect(step2)
    #expect(settings.inputOrder == ["a", "c", "b"])

    // Two visible rows leave nowhere further to go.
    rows = settings.devices([a, b, c], role: .input)
    let step3 = settings.move(try #require(rows.first { $0.uid == "c" }), by: 1, in: rows)
    #expect(!step3)
    let step4 = settings.move(try #require(rows.first { $0.uid == "a" }), by: -1, in: rows)
    #expect(!step4)
    #expect(settings.inputOrder == ["a", "c", "b"])
}

@Test func hiddenDeviceCannotBeReorderedAndReturnsToItsSavedPlace() throws {
    var settings = RoutePreferences()
    let a = microphone("a"), b = microphone("b"), c = microphone("c")
    settings.remember([a, b, c])
    settings.inputOrder = ["a", "b", "c"]
    settings.setHidden(true, device: try #require(settings.devices([a, b, c], role: .input).first { $0.uid == "b" }))

    let rows = settings.devices([a, b, c], role: .input)
    let hidden = try #require(rows.first { $0.uid == "b" })
    let step5 = settings.move(hidden, by: -1, in: rows)
    #expect(!step5)
    let step6 = settings.move(hidden, by: 1, in: rows)
    #expect(!step6)
    #expect(settings.inputOrder == ["a", "b", "c"])

    settings.setHidden(false, device: hidden)
    #expect(settings.devices([a, b, c], role: .input).map(\.uid) == ["a", "b", "c"])
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

@Test func forgettingADisconnectedDeviceRemovesEveryPortItWasSeenOn() throws {
    var settings = RoutePreferences()
    let a = microphone(usbA, port: true)
    let b = microphone(usbB, port: true)
    let builtin = microphone("builtin")
    settings.remember([a, builtin])
    settings.remember([b, builtin])
    settings.inputOrder = [usbA, "builtin", usbB]
    let offline = try #require(settings.devices([builtin], role: .input).first { !$0.isConnected })
    settings.levelsBeforeMute[offline.id] = 0.5
    settings.inputHold = offline.id
    settings.outputHold = "output:uid:speakers"

    settings.forget(offline)
    #expect(settings.records.map(\.uid) == ["builtin"])
    #expect(settings.inputOrder == ["builtin"])
    #expect(settings.levelsBeforeMute.isEmpty)
    #expect(settings.inputHold == nil)
    #expect(settings.outputHold == "output:uid:speakers")
    #expect(settings.devices([builtin], role: .input).map(\.uid) == ["builtin"])

    // Seen again, it starts over as a new unranked, visible row.
    settings.remember([a, builtin])
    let returned = try #require(settings.devices([a, builtin], role: .input).first { $0.uid == usbA })
    #expect(!returned.isHidden)
    #expect(!settings.rankedIDs(for: .input).contains(returned.id))
}

@Test func forgettingOneRoleKeepsTheSameDevicesOtherRole() throws {
    var settings = RoutePreferences()
    let headsetIn = Endpoint(objectID: 1, uid: "headset", name: "Headset", role: .input)
    let headsetOut = Endpoint(objectID: 1, uid: "headset", name: "Headset", role: .output)
    settings.remember([headsetIn, headsetOut])
    settings.inputOrder = ["headset"]
    settings.outputOrder = ["headset"]
    settings.forget(try #require(settings.devices([], role: .input).first))
    #expect(settings.records.map(\.role) == [.output])
    #expect(settings.inputOrder.isEmpty)
    #expect(settings.outputOrder == ["headset"])
}
