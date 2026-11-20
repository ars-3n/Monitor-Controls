import Foundation

public enum RouteRole: String, Codable, CaseIterable, Sendable {
    case input, output
}

public struct RouteDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let uid: String
    public let name: String
    public let role: RouteRole
    public let isDisplay: Bool
    public let isHidden: Bool
    public let isConnected: Bool
    public let isVirtual: Bool
}

struct Endpoint: Equatable, Sendable {
    var objectID: UInt32
    var uid: String
    var name: String
    var role: RouteRole
    var isDisplay = false
    var isVirtual = false
    var followsPort: Bool? = false
}

struct RememberedRoute: Codable, Equatable {
    let uid: String
    var name: String
    let role: RouteRole
    var isDisplay: Bool
    var isVirtual: Bool
    var followsPort: Bool?
    var hidden: Bool?
    var hiddenRevision = 0

    init(_ endpoint: Endpoint) {
        uid = endpoint.uid
        name = endpoint.name
        role = endpoint.role
        isDisplay = endpoint.isDisplay
        isVirtual = endpoint.isVirtual
        followsPort = endpoint.followsPort
    }
}

struct RoutePreferences: Codable, Equatable {
    var records: [RememberedRoute] = []
    var ambiguousFamilies: Set<String> = []
    var inputOrder: [String] = []
    var outputOrder: [String] = []
    var importedLegacy = false
    var inputHold: String?
    var outputHold: String?
    // A scalar fallback must survive app restarts. Zero without a recorded
    // app-initiated mute is simply a volume level, not a reversible mute.
    var levelsBeforeMute: [String: Double] = [:]

    func order(for role: RouteRole) -> [String] { role == .input ? inputOrder : outputOrder }

    mutating func setOrder(_ order: [String], for role: RouteRole) {
        if role == .input { inputOrder = order } else { outputOrder = order }
    }

    mutating func remember(_ endpoints: [Endpoint]) {
        var portsByFamily: [String: Set<String>] = [:]
        for endpoint in endpoints {
            var followsPort = endpoint.followsPort
            if let i = records.firstIndex(where: { $0.role == endpoint.role && $0.uid == endpoint.uid }) {
                records[i].name = endpoint.name
                records[i].isDisplay = endpoint.isDisplay
                records[i].isVirtual = endpoint.isVirtual
                if let confirmed = followsPort { records[i].followsPort = confirmed }
                followsPort = records[i].followsPort
            } else {
                records.append(RememberedRoute(endpoint))
            }
            if followsPort == true, let port = PortIdentity(endpoint.uid) {
                portsByFamily[port.family, default: []].insert(port.port)
            }
        }
        for (family, ports) in portsByFamily where ports.count > 1 {
            ambiguousFamilies.insert(family)
        }
    }

    private func identifier(_ record: RememberedRoute) -> String {
        let role = record.role.rawValue
        if record.followsPort == true, let port = PortIdentity(record.uid), !ambiguousFamilies.contains(port.family) {
            return "\(role):port:\(port.family):\(port.endpoint)"
        }
        return "\(role):uid:\(record.uid)"
    }

    func devices(_ endpoints: [Endpoint], role: RouteRole) -> [RouteDevice] {
        // Coalesce ports only while the evidence supports it. Keep original
        // per-port settings intact so discovering two identical devices can
        // immediately restore each one's own visibility and priority.
        let groups = Dictionary(grouping: records.filter { $0.role == role }, by: identifier)
        let ranks = Dictionary(order(for: role).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let connected = Set(endpoints.filter { $0.role == role }.map(\.uid))
        return groups.map { id, group in
            let current = group.first { connected.contains($0.uid) }
            let record = current ?? group.last!
            let visibility = group.filter { $0.hidden != nil }.max { $0.hiddenRevision < $1.hiddenRevision }
            return (RouteDevice(id: id, uid: record.uid, name: record.name, role: role, isDisplay: record.isDisplay,
                                isHidden: visibility?.hidden ?? false, isConnected: current != nil, isVirtual: record.isVirtual),
                    group.compactMap { ranks[$0.uid] }.min() ?? Int.max)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let comparison = lhs.0.name.localizedStandardCompare(rhs.0.name)
            return comparison == .orderedSame ? lhs.0.id < rhs.0.id : comparison == .orderedAscending
        }.map(\.0)
    }

    func rankedIDs(for role: RouteRole) -> Set<String> {
        let ranked = Set(order(for: role))
        guard !ranked.isEmpty else { return [] }
        return Set(records.lazy.filter { $0.role == role && ranked.contains($0.uid) }.map(identifier))
    }

    mutating func setHidden(_ value: Bool, device: RouteDevice) {
        guard let i = records.firstIndex(where: { $0.uid == device.uid && $0.role == device.role }) else { return }
        let revision = (records.map(\.hiddenRevision).max() ?? 0) + 1
        records[i].hidden = value
        records[i].hiddenRevision = revision
    }

    /// Drops everything saved for a device, including the other ports it was
    /// seen on. It gets a new row with default settings if it connects again.
    mutating func forget(_ device: RouteDevice) {
        let aliases = Set(records.filter { $0.role == device.role && identifier($0) == device.id }.map(\.uid))
        guard !aliases.isEmpty else { return }
        records.removeAll { $0.role == device.role && aliases.contains($0.uid) }
        setOrder(order(for: device.role).filter { !aliases.contains($0) }, for: device.role)
        levelsBeforeMute[device.id] = nil
        if inputHold == device.id { inputHold = nil }
        if outputHold == device.id { outputHold = nil }
    }

    mutating func move(_ device: RouteDevice, by offset: Int, in devices: [RouteDevice]) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == device.id }),
              offset > -devices.count, offset < devices.count, devices.indices.contains(index + offset), offset != 0 else { return false }
        var reordered = devices
        reordered.insert(reordered.remove(at: index), at: index + offset)
        // Preserve historical raw-port ranks adjacent to the current visible
        // row rather than losing an offline device's rank during reordering.
        let existing = order(for: device.role)
        let groups = Dictionary(grouping: records.filter { $0.role == device.role }, by: identifier)
        var updated: [String] = []
        for row in reordered {
            updated.append(row.uid)
            let aliases = Set(groups[row.id, default: []].map(\.uid)).subtracting([row.uid])
            updated += existing.filter { aliases.contains($0) }
        }
        updated += existing.filter { !updated.contains($0) }
        setOrder(updated, for: device.role)
        return true
    }
}

// Saved preferences outlive the build that wrote them. Read every field
// that is present and default the others, so a field added later cannot make
// an older file unreadable and reset the user's device order.
extension RememberedRoute {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uid = try values.decode(String.self, forKey: .uid)
        role = try values.decode(RouteRole.self, forKey: .role)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? uid
        isDisplay = try values.decodeIfPresent(Bool.self, forKey: .isDisplay) ?? false
        isVirtual = try values.decodeIfPresent(Bool.self, forKey: .isVirtual) ?? false
        followsPort = try values.decodeIfPresent(Bool.self, forKey: .followsPort)
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden)
        hiddenRevision = try values.decodeIfPresent(Int.self, forKey: .hiddenRevision) ?? 0
    }
}

extension RoutePreferences {
    private struct SavedValue<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        records = (try? values.decode([SavedValue<RememberedRoute>].self, forKey: .records))?.compactMap(\.value) ?? []
        // Keep the entries that can be read. Two identical devices are told
        // apart again the next time both are connected.
        let families = try? values.decode([SavedValue<String>].self, forKey: .ambiguousFamilies)
        ambiguousFamilies = Set(families?.compactMap(\.value) ?? [])
        inputOrder = (try? values.decode([SavedValue<String>].self, forKey: .inputOrder))?.compactMap(\.value) ?? []
        outputOrder = (try? values.decode([SavedValue<String>].self, forKey: .outputOrder))?.compactMap(\.value) ?? []
        importedLegacy = (try? values.decode(Bool.self, forKey: .importedLegacy)) ?? false
        inputHold = try? values.decode(String.self, forKey: .inputHold)
        outputHold = try? values.decode(String.self, forKey: .outputHold)
        let savedLevels = (try? values.decode([String: SavedValue<Double>].self, forKey: .levelsBeforeMute)) ?? [:]
        levelsBeforeMute = savedLevels.compactMapValues { entry in
            guard let level = entry.value, (0...1).contains(level) else { return nil }
            return level
        }
    }
}

struct RoutePolicy {
    var heldID: String?
    private var connected: Set<String> = []
    private var previousUID: String?
    private var recentJoins: [String: TimeInterval] = [:]
    private var initialized = false
    private var awaitingInputFallback = false
    private var pendingSelection: (target: String, superseded: Set<String>, expires: TimeInterval)?

    init(heldID: String? = nil) {
        self.heldID = heldID
    }

    mutating func desired(current: RouteDevice?, devices: [RouteDevice], rankedIDs: Set<String>,
                          time: TimeInterval) -> RouteDevice? {
        let live = devices.filter(\.isConnected)
        let present = Set(live.map(\.id))
        // HAL can publish connected devices before the default at login.
        // Preserve the saved choice until we can compare it with macOS.
        if !initialized, current == nil { return nil }
        recentJoins = recentJoins.filter { present.contains($0.key) && time - $0.value < 5 }
        if initialized {
            for id in present.subtracting(connected) { recentJoins[id] = time }
        }
        if let heldID, !present.contains(heldID) {
            self.heldID = nil
            // Volatile snapshots may briefly have no default at all. Pin the
            // eventual replacement mic as soon as macOS publishes it.
            awaitingInputFallback = devices.first?.role == .input || devices.isEmpty
        }
        if awaitingInputFallback, let current {
            if current.role == .input, !current.isHidden { heldID = current.id }
            awaitingInputFallback = false
        }
        // A successful set-default call can return before the getter changes.
        // The old snapshot is neither an external pick nor a reason to repeat
        // the write. A genuine move to a third device is still handled below.
        let acknowledgingOwnWrite = current?.id != nil && current?.id == pendingSelection?.target
        if let pendingSelection, present.contains(pendingSelection.target),
           time < pendingSelection.expires, !acknowledgingOwnWrite,
           current == nil || current.map({ pendingSelection.superseded.contains($0.id) }) == true
                || (!initialized && previousUID == nil) {
            connected = present
            if let current { previousUID = current.id }
            initialized = true
            return nil
        }
        pendingSelection = nil
        if !acknowledgingOwnWrite, let current, let previousUID, previousUID != current.id, present.contains(previousUID),
           connected.contains(current.id), recentJoins[current.id] == nil {
            heldID = current.id
        } else if !initialized, heldID != nil, let current, heldID != current.id {
            // An explicit choice made while the app wasn't running wins.
            heldID = current.id
        }
        // During handover macOS may temporarily have no default. Preserve
        // the last known device so a subsequent external pick is recognized.
        if let current { previousUID = current.id }
        connected = present
        initialized = true
        if let held = live.first(where: { $0.id == heldID }) { return held }
        if let ranked = live.first(where: { rankedIDs.contains($0.id) && !$0.isHidden }) { return ranked }
        if current?.isHidden == true {
            return live.first { !$0.isHidden && !$0.isVirtual } ?? live.first { !$0.isHidden } ?? current
        }
        return current
    }

    mutating func didSelect(_ device: RouteDevice, manually: Bool, replacing current: RouteDevice? = nil,
                            time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var superseded = Set([current?.id, previousUID].compactMap { $0 })
        if let previous = pendingSelection, time < previous.expires {
            superseded.formUnion(previous.superseded)
            superseded.insert(previous.target)
        }
        pendingSelection = (device.id, superseded, time + 1)
        if manually { heldID = device.id }
    }
}
