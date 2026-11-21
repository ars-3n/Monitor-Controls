import Foundation
import Testing
@testable import AudioRouting

private func device(_ name: String, role: RouteRole = .output, virtual: Bool = false, internal isInternal: Bool = false) -> Endpoint {
    Endpoint(objectID: 1, uid: name, name: name, role: role, isVirtual: virtual, isInternal: isInternal)
}

private let speakers = device("MacBook Air Speakers", internal: true)
private let monitor = device("LG ULTRAWIDE")
private let dac = device("USB Audio Device")
private let pods = device("AirPods Pro")
private let loopback = device("BlackHole 2ch", virtual: true)

@Test func anUnarrangedListPutsConnectedDevicesFirstAndVirtualOnesLast() {
    var settings = RoutePreferences()
    let all = [loopback, speakers, dac, monitor, pods]
    settings.remember(all)
    #expect(settings.outputOrder.isEmpty)
    #expect(settings.devices(all, role: .output).map(\.name)
            == ["AirPods Pro", "LG ULTRAWIDE", "USB Audio Device", "MacBook Air Speakers", "BlackHole 2ch"])
}

@Test func aNewDeviceTakesItsPlaceInAnArrangedList() {
    var settings = RoutePreferences()
    settings.remember([monitor, speakers, loopback])
    settings.outputOrder = [monitor.uid, speakers.uid, loopback.uid]
    settings.remember([monitor, speakers, loopback, pods, dac])
    #expect(settings.devices([], role: .output).map(\.name)
            == ["LG ULTRAWIDE", "AirPods Pro", "USB Audio Device", "MacBook Air Speakers", "BlackHole 2ch"])

    // An order that puts the Mac's own speakers first is left that way.
    settings.outputOrder = [speakers.uid, monitor.uid]
    #expect(settings.devices([], role: .output).map(\.name)
            == ["MacBook Air Speakers", "LG ULTRAWIDE", "AirPods Pro", "USB Audio Device", "BlackHole 2ch"])
}

@Test func theListedOrderIsFollowedBeforeAnyArrowIsPressed() {
    var settings = RoutePreferences()
    let all = [speakers, monitor, loopback]
    settings.remember(all)
    let rows = settings.devices(all, role: .output)
    var policy = RoutePolicy()
    let current = rows.first { $0.name == "MacBook Air Speakers" }
    #expect(policy.desired(current: current, devices: rows, rankedIDs: Set(rows.map(\.id)), time: 0)?.name == "LG ULTRAWIDE")

    // Unplugged, the next device in the list is used.
    settings.remember([speakers, loopback])
    let undocked = settings.devices([speakers, loopback], role: .output)
    #expect(policy.desired(current: current, devices: undocked, rankedIDs: Set(undocked.map(\.id)), time: 100)?.name
            == "MacBook Air Speakers")
}

@Test func pressingAnArrowSavesTheListAsShown() throws {
    var settings = RoutePreferences()
    let all = [loopback, speakers, dac, monitor]
    settings.remember(all)
    let rows = settings.devices(all, role: .output)
    let moved = settings.move(try #require(rows.first { $0.name == "USB Audio Device" }), by: -1, in: rows)
    #expect(moved)
    #expect(settings.outputOrder == ["USB Audio Device", "LG ULTRAWIDE", "MacBook Air Speakers", "BlackHole 2ch"])
}

@Test func aSavedDeviceWithoutTheNewFieldStillLoads() throws {
    let saved = Data(#"{"records":[{"uid":"BuiltInSpeakerDevice","name":"MacBook Air Speakers","role":"output"}]}"#.utf8)
    var settings = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    #expect(settings.records.first?.isInternal == false)
    settings.remember([Endpoint(objectID: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Air Speakers", role: .output, isInternal: true)])
    #expect(settings.records.first?.isInternal == true)
}
