/// The devices a panel row lists before "Show all": the first `limit` in
/// priority order. An active device that ranks lower takes the last place.
public func shortlist<ID: Equatable>(_ ordered: [ID], active: ID?, limit: Int) -> [ID] {
    var list = Array(ordered.prefix(max(0, limit)))
    if let active, !list.isEmpty, !list.contains(active), ordered.contains(active) {
        list[list.count - 1] = active
    }
    return list
}
