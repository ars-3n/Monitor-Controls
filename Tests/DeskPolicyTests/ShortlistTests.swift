import DeskPolicy
import Testing

@Test func shortlistKeepsTheFirstDevicesInOrder() {
    #expect(shortlist(["a", "b", "c", "d"], active: "b", limit: 3) == ["a", "b", "c"])
    #expect(shortlist(["a", "b"], active: nil, limit: 3) == ["a", "b"])
}

@Test func shortlistShowsALowerRankedActiveDeviceLast() {
    #expect(shortlist(["a", "b", "c", "d", "e"], active: "e", limit: 3) == ["a", "b", "e"])
}

@Test func shortlistIgnoresAnActiveDeviceThatIsNotListed() {
    #expect(shortlist(["a", "b", "c", "d"], active: "x", limit: 3) == ["a", "b", "c"])
    #expect(shortlist([String](), active: "x", limit: 3).isEmpty)
    #expect(shortlist(["a"], active: "a", limit: 0).isEmpty)
}
