import Foundation
import Testing
@testable import AudioRouting

private let family = "AppleUSBAudioEngine:Generic:USB Audio Device"

private func dongle(_ port: String, model: String? = nil) -> Endpoint {
    Endpoint(objectID: 1, uid: "\(family):\(port):1", name: "USB Audio Device", role: .output, followsPort: true, model: model)
}

private let speakers = Endpoint(objectID: 2, uid: "speakers", name: "Speakers", role: .output, isInternal: true)

@Test func lookAlikeModelsAreNotTakenForTwins() {
    var settings = RoutePreferences()
    let first = dongle("01000000", model: "1b3f:2008")
    let second = dongle("02000000", model: "0d8c:0014")
    settings.remember([first, speakers])
    settings.outputOrder = [speakers.uid, first.uid]
    settings.remember([first, second, speakers])
    #expect(settings.ambiguousFamilies.isEmpty)

    // Each model is one device on any port, with its own place in the list.
    let moved = dongle("03000000", model: "1b3f:2008")
    settings.remember([moved, speakers])
    let rows = settings.devices([moved, speakers], role: .output)
    #expect(rows.map(\.uid) == [speakers.uid, moved.uid, second.uid])
    #expect(rows.map(\.isConnected) == [true, true, false])
}

@Test func aSecondModelOnAUsedPortDoesNotTakeTheFirstOnesPlace() {
    var settings = RoutePreferences()
    let first = dongle("01000000", model: "1b3f:2008")
    settings.remember([first, speakers])
    settings.outputOrder = [first.uid, speakers.uid]
    settings.remember([speakers])

    let other = dongle("01000000", model: "0d8c:0014")
    settings.remember([other, speakers])
    let rows = settings.devices([other, speakers], role: .output)
    #expect(rows.count == 3)
    #expect(rows.first?.isConnected == false)
    #expect(Set(rows.map(\.id)).count == 3)

    // The first model is still found when it comes back to that port.
    settings.remember([first, speakers])
    #expect(settings.devices([first, speakers], role: .output).map(\.isConnected) == [true, false, true])
    #expect(settings.records.count == 3)
}

@Test func aRecordSavedBeforeModelsWereReadKeepsItsPlace() throws {
    let saved = Data("""
    {"records":[{"uid":"\(family):01000000:1","role":"output","followsPort":true},
                {"uid":"\(family):02000000:1","role":"output","followsPort":true},
                {"uid":"speakers","role":"output","isInternal":true}],
     "outputOrder":["speakers","\(family):02000000:1"]}
    """.utf8)
    var settings = try JSONDecoder().decode(RoutePreferences.self, from: saved)
    let now = dongle("01000000", model: "1b3f:2008")
    settings.remember([now, speakers])
    #expect(settings.devices([now, speakers], role: .output).map(\.uid) == [speakers.uid, now.uid])
}

@Test func aTwinOnANewPortTakesThePlaceOfTheOneUsedLast() {
    var settings = RoutePreferences()
    let a = dongle("01000000"), b = dongle("02000000")
    settings.remember([a, b, speakers])
    #expect(settings.ambiguousFamilies == [family])
    settings.outputOrder = [b.uid, speakers.uid, a.uid]
    settings.setHidden(true, device: settings.devices([], role: .output).first { $0.uid == a.uid }!)

    settings.remember([a, speakers])
    settings.remember([speakers])
    let elsewhere = dongle("03000000")
    settings.remember([elsewhere, speakers])
    let rows = settings.devices([elsewhere, speakers], role: .output)
    #expect(rows.map(\.uid) == [b.uid, speakers.uid, elsewhere.uid, a.uid])
    #expect(rows.first { $0.uid == elsewhere.uid }?.isHidden == true)

    // Nothing more changes while it stays connected.
    let settled = settings
    settings.remember([elsewhere, speakers])
    #expect(settings == settled)

    // The other one was not used since, so the next new port follows this one too.
    settings.remember([speakers])
    let again = dongle("04000000")
    settings.remember([again, speakers])
    #expect(settings.devices([again, speakers], role: .output).map(\.uid) == [b.uid, speakers.uid, again.uid, elsewhere.uid, a.uid])
}

@Test func aTwinSeenForTheFirstTimeGoesBelowItsSibling() {
    var settings = RoutePreferences()
    let a = dongle("01000000"), b = dongle("02000000")
    settings.remember([a, speakers])
    settings.outputOrder = [a.uid, speakers.uid]
    settings.remember([a, b, speakers])
    #expect(settings.devices([a, b, speakers], role: .output).map(\.uid) == [a.uid, b.uid, speakers.uid])
}
