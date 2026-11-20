import Foundation
import Testing
@testable import AudioRouting

private func output(_ objectID: UInt32 = 1, uid: String = "display") -> Endpoint {
    Endpoint(objectID: objectID, uid: uid, name: "Display", role: .output, isDisplay: true)
}

private func route(_ uid: String) -> RouteDevice {
    RouteDevice(id: uid, uid: uid, name: uid, role: .input, isDisplay: false, isHidden: false, isConnected: true, isVirtual: false)
}

@Test func aLateHALAcknowledgementDoesNotCancelAManualPick() {
    let old = route("usb"), chosen = route("airpods"), other = route("laptop")
    var state = RoutePolicy()
    let devices = [old, chosen, other]
    _ = state.desired(current: old, devices: devices, rankedIDs: [old.id], time: 1)
    state.didSelect(chosen, manually: true, time: 2)
    let beforeConfirmation = state.desired(current: old, devices: devices, rankedIDs: [old.id], time: 2.1)
    #expect(beforeConfirmation == nil)
    #expect(state.heldID == chosen.id)
    #expect(state.desired(current: chosen, devices: devices, rankedIDs: [old.id], time: 2.2) == chosen)
    #expect(state.desired(current: other, devices: devices, rankedIDs: [], time: 3) == other)
    #expect(state.heldID == other.id)
}

@Test func automaticWriteAcknowledgementIsNotRecordedAsManual() {
    let a = route("a"), b = route("b")
    let devices = [a, b]
    var state = RoutePolicy()
    #expect(state.desired(current: a, devices: devices, rankedIDs: [b.id], time: 0) == b)
    state.didSelect(b, manually: false, time: 1)
    #expect(state.desired(current: a, devices: devices, rankedIDs: [b.id], time: 1.2) == nil)
    #expect(state.desired(current: b, devices: devices, rankedIDs: [b.id], time: 1.3) == b)
    #expect(state.heldID == nil)
    #expect(state.desired(current: b, devices: devices, rankedIDs: [a.id], time: 2) == a)
}

@Test func deviceSelectedElsewhereCanSupersedeAnInFlightWrite() {
    let a = route("a"), b = route("b"), c = route("c")
    let devices = [a, b, c]
    var state = RoutePolicy()
    _ = state.desired(current: a, devices: devices, rankedIDs: [], time: 0)
    state.didSelect(b, manually: true, time: 1)
    #expect(state.desired(current: c, devices: devices, rankedIDs: [], time: 1.2) == c)
    #expect(state.heldID == c.id)
}

@Test func outputGuardRejectsRecycledObjectIDsAndTripsAcrossRestart() throws {
    let tracker = OutputIdentity()
    let original = output()
    let replacement = output(2)
    #expect(tracker.update(objectID: original.objectID, uid: original.uid))
    let guardACandidate = tracker.guardFor(original, checkLive: { true })
    let guardA = try #require(guardACandidate)
    #expect(guardA())
    #expect(!tracker.update(objectID: original.objectID, uid: original.uid))
    #expect(tracker.update(objectID: replacement.objectID, uid: replacement.uid))
    #expect(!guardA())
    #expect(tracker.guardFor(original, checkLive: { true }) == nil)
    #expect(tracker.update(objectID: original.objectID, uid: original.uid))
    #expect(!guardA())
    let freshCandidate = tracker.guardFor(original, checkLive: { true })
    let fresh = try #require(freshCandidate)
    #expect(fresh())
    tracker.invalidate()
    _ = tracker.update(objectID: original.objectID, uid: original.uid)
    #expect(!fresh())
    let differentLiveCandidate = tracker.guardFor(original, checkLive: { false })
    let differentLive = try #require(differentLiveCandidate)
    #expect(!differentLive())
}

@Test func outputCanChangeDuringTheHardwareGuardCheck() throws {
    let tracker = OutputIdentity()
    let speaker = output()
    _ = tracker.update(objectID: speaker.objectID, uid: speaker.uid)
    let candidate = tracker.guardFor(speaker) {
        tracker.invalidate()
        return true
    }
    let check = try #require(candidate)
    #expect(!check())
}

@Test func incompleteSnapshotIsRetriedRatherThanDeclaringDefaultDisconnected() {
    let speaker = output()
    #expect(AudioSnapshot(endpoints: [speaker], inputID: nil, outputID: 2) == nil)
    #expect(AudioSnapshot(endpoints: [speaker], inputID: 1, outputID: 1) == nil)
    #expect(AudioSnapshot(endpoints: [speaker], inputID: nil, outputID: 1) != nil)
    #expect(AudioSnapshot(endpoints: [], inputID: nil, outputID: nil) != nil)
}

@MainActor @Test func gainMuteKeepsOriginalLevelThroughDelayedZeroAndReopens() {
    let recovery = GainMuteRecovery()
    var saved: Double?
    var writes: [Double] = []
    let muted = recovery.set(true, id: "USB", current: 0.72, saved: nil, save: { saved = $0 }, write: { writes.append($0); return true })
    #expect(muted)
    // The driver has accepted the request and still reports its old gain.
    let early = recovery.isMuted(id: "USB", current: 0.72, saved: saved, save: { saved = $0 })
    #expect(!early && saved == 0.72)
    let confirmed = recovery.isMuted(id: "USB", current: 0, saved: saved, save: { saved = $0 })
    #expect(confirmed)
    let reopened = GainMuteRecovery()
    let restored = reopened.set(false, id: "USB", current: 0, saved: saved, save: { saved = $0 }, write: { writes.append($0); return true })
    #expect(restored && saved == nil && writes == [0, 0.72])
}

@MainActor @Test func unmuteCanCancelAnInFlightGainMuteAndRetainReceiptIfRestoreFails() {
    let recovery = GainMuteRecovery()
    var saved: Double?
    var writes: [Double] = []
    _ = recovery.set(true, id: "mic", current: 0.4, saved: nil, save: { saved = $0 }, write: { writes.append($0); return true })
    let failed = recovery.set(false, id: "mic", current: 0.4, saved: saved, save: { saved = $0 }, write: { _ in false })
    #expect(!failed && saved == 0.4)
    let retried = recovery.set(false, id: "mic", current: 0.4, saved: saved, save: { saved = $0 }, write: { writes.append($0); return true })
    #expect(retried && saved == nil && writes == [0, 0.4])
}

@MainActor @Test func externalGainChangeClearsMuteRecovery() {
    let recovery = GainMuteRecovery()
    var saved: Double? = 0.23
    let muted = recovery.isMuted(id: "mic", current: 0.9, saved: saved, save: { saved = $0 })
    #expect(!muted && saved == nil)
}

@Test func malformedLegacyRowsDoNotDiscardIndependentDeviceIdentity() throws {
    let valid: [String: Any] = ["uid": "real", "name": "USB microphone", "isInput": true]
    let invalid: [String: Any] = ["uid": 34, "name": false]
    let data = try JSONSerialization.data(withJSONObject: [invalid, valid])
    var saved = RoutePreferences()
    let imported = saved.importLegacy(["knownDevices": data, "inputPriorities": ["real"]])
    #expect(imported)
    #expect(saved.devices([], role: .input).first?.name == "USB microphone")
}

@Test func firstManualPickWhileIdentityIsSettlingSurvivesStaleDefault() {
    let mic = route("a"), pods = route("b")
    var state = RoutePolicy()
    state.didSelect(pods, manually: true, replacing: mic, time: 1)
    #expect(state.desired(current: mic, devices: [mic, pods], rankedIDs: [], time: 1.1) == nil)
    #expect(state.heldID == pods.id)
    #expect(state.desired(current: pods, devices: [mic, pods], rankedIDs: [], time: 1.2) == pods)
}

@Test func consecutiveManualPicksIgnoreTheEarlierDelayedAcknowledgement() {
    let a = route("a"), b = route("b"), c = route("c")
    let devices = [a, b, c]
    var state = RoutePolicy()
    _ = state.desired(current: a, devices: devices, rankedIDs: [], time: 0)
    state.didSelect(b, manually: true, replacing: a, time: 1)
    state.didSelect(c, manually: true, replacing: a, time: 1.1)
    #expect(state.desired(current: b, devices: devices, rankedIDs: [], time: 1.2) == nil)
    #expect(state.heldID == c.id)
    #expect(state.desired(current: c, devices: devices, rankedIDs: [], time: 1.3) == c)
}

@Test func twoConnectedKnownUSBPortsStaySeparateWhileOneDescriptorIsLate() {
    let first = Endpoint(objectID: 3, uid: "AppleUSBAudioEngine:Maker:Mic:01000000:1", name: "Mic", role: .input, followsPort: true)
    var second = Endpoint(objectID: 4, uid: "AppleUSBAudioEngine:Maker:Mic:02000000:1", name: "Mic", role: .input, followsPort: true)
    var preferences = RoutePreferences()
    preferences.remember([first])
    preferences.remember([second])
    second.followsPort = nil
    preferences.remember([first, second])
    let devices = preferences.devices([first, second], role: .input)
    #expect(devices.count == 2 && devices.allSatisfy(\.isConnected))
}

@Test func savedPreferencesSurviveMissingFieldsAndOneDamagedRecord() throws {
    // Written by a build that knew fewer fields, with one record of an unknown role.
    let saved = Data("""
    {"records": [{"uid": "usb-a", "name": "Desk DAC", "role": "output", "hidden": true},
                 {"uid": "future", "name": "Later", "role": "haptics"},
                 {"uid": "mic-b", "role": "input"}],
     "outputOrder": ["usb-a"], "outputHold": "output:uid:usb-a", "someLaterField": 3}
    """.utf8)
    let preferences = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    #expect(preferences.records.map(\.uid) == ["usb-a", "mic-b"])
    #expect(preferences.records[0].hidden == true)
    #expect(preferences.records[0].hiddenRevision == 0)
    #expect(preferences.records[1].name == "mic-b")
    #expect(preferences.outputOrder == ["usb-a"])
    #expect(preferences.outputHold == "output:uid:usb-a")
    #expect(preferences.inputOrder.isEmpty)
    #expect(!preferences.importedLegacy)
    #expect(preferences.levelsBeforeMute.isEmpty)

    // What this build writes still reads back unchanged.
    var current = RoutePreferences()
    current.remember([Endpoint(objectID: 1, uid: "usb-a", name: "Desk DAC", role: .output, followsPort: nil)])
    current.setHidden(true, device: current.devices([], role: .output)[0])
    current.levelsBeforeMute["output:uid:usb-a"] = 0.4
    current.inputHold = "input:uid:mic-b"
    let copy = try JSONDecoder().decode(RoutePreferences.self, from: JSONEncoder().encode(current))
    #expect(copy == current)
}

@Test func damagedPreferenceFieldsPreserveRoutingAndOtherMuteLevels() throws {
    let saved = Data("""
    {"records":[{"uid":"speaker","role":"output","hidden":true}],
     "outputOrder":["speaker"], "outputHold":"output:uid:speaker",
     "inputOrder":false, "levelsBeforeMute":{"usb":0.72,"bad":"unknown","invalid":8}}
    """.utf8)
    let preferences = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    #expect(preferences.inputOrder.isEmpty)
    #expect(preferences.outputOrder == ["speaker"])
    #expect(preferences.outputHold == "output:uid:speaker")
    #expect(preferences.records.first?.hidden == true)
    #expect(preferences.levelsBeforeMute == ["usb": 0.72])
}

private func savedMicOnTwoPorts(ambiguousFamilies: String) throws -> RoutePreferences {
    let saved = Data("""
    {"ambiguousFamilies":\(ambiguousFamilies),"records":[
      {"uid":"AppleUSBAudioEngine:Maker:Mic:01000000:1","role":"input","followsPort":true},
      {"uid":"AppleUSBAudioEngine:Maker:Mic:02000000:1","role":"input","followsPort":true}
    ]}
    """.utf8)
    return try JSONDecoder().decode(RoutePreferences.self, from: saved)
}

@Test func damagedAmbiguityHistoryKeepsItsReadableEntries() throws {
    let preferences = try savedMicOnTwoPorts(ambiguousFamilies: #"["AppleUSBAudioEngine:Maker:Mic",5]"#)
    #expect(preferences.ambiguousFamilies == ["AppleUSBAudioEngine:Maker:Mic"])
    #expect(preferences.devices([], role: .input).count == 2)
}

@Test func unreadableAmbiguityHistoryDoesNotSplitOneDeviceByPort() throws {
    var preferences = try savedMicOnTwoPorts(ambiguousFamilies: "false")
    #expect(preferences.devices([], role: .input).count == 1)
    // Seeing both ports in use at once shows there are two devices.
    let both = ["01000000", "02000000"].enumerated().map { index, port in
        Endpoint(objectID: UInt32(index + 1), uid: "AppleUSBAudioEngine:Maker:Mic:\(port):1", name: "Mic", role: .input, followsPort: true)
    }
    preferences.remember(both)
    #expect(preferences.devices(both, role: .input).count == 2)
}
