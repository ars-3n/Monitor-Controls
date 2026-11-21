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
    /// Part of the Mac and always present: its own speakers or microphone.
    var isInternal = false
    var followsPort: Bool? = false
}

struct RememberedRoute: Codable, Equatable {
    let uid: String
    var name: String
    let role: RouteRole
    var isDisplay: Bool
    var isVirtual: Bool
    var isInternal: Bool
    var followsPort: Bool?
    var hidden: Bool?
    var hiddenRevision = 0

    init(_ endpoint: Endpoint) {
        uid = endpoint.uid
        name = endpoint.name
        role = endpoint.role
        isDisplay = endpoint.isDisplay
        isVirtual = endpoint.isVirtual
        isInternal = endpoint.isInternal
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
    /// The devices that were connected when each hold was made and have stayed connected.
    var inputPassedOver: Set<String> = []
    var outputPassedOver: Set<String> = []
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
                records[i].isInternal = endpoint.isInternal
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

    /// The devices in priority order. This is the order Settings shows and
    /// the order automatic switching follows.
    func devices(_ endpoints: [Endpoint], role: RouteRole) -> [RouteDevice] {
        // Coalesce ports only while the evidence supports it. Keep original
        // per-port settings intact so discovering two identical devices can
        // immediately restore each one's own visibility and priority.
        let groups = Dictionary(grouping: records.filter { $0.role == role }, by: identifier)
        let ranks = Dictionary(order(for: role).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let connected = Set(endpoints.filter { $0.role == role }.map(\.uid))
        let rows = groups.map { id, group in
            let current = group.first { connected.contains($0.uid) }
            let record = current ?? group.last!
            let visibility = group.filter { $0.hidden != nil }.max { $0.hiddenRevision < $1.hiddenRevision }
            return (device: RouteDevice(id: id, uid: record.uid, name: record.name, role: role, isDisplay: record.isDisplay,
                                        isHidden: visibility?.hidden ?? false, isConnected: current != nil, isVirtual: record.isVirtual),
                    rank: group.compactMap { ranks[$0.uid] }.min(),
                    // Something the user connects, then the Mac's own, then a device an app created.
                    kind: record.isVirtual ? 2 : record.isInternal ? 1 : 0)
        }
        func byName(_ lhs: RouteDevice, _ rhs: RouteDevice) -> Bool {
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        var ordered = rows.filter { $0.rank != nil }.sorted {
            $0.rank! != $1.rank! ? $0.rank! < $1.rank! : byName($0.device, $1.device)
        }
        // A device that was never given a place goes below the last device
        // of its kind or a kind before it, and above everything if there is none.
        let unplaced = rows.filter { $0.rank == nil }.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind : byName($0.device, $1.device)
        }
        for row in unplaced {
            let above = ordered.lastIndex { $0.kind <= row.kind }
            ordered.insert(row, at: above.map { $0 + 1 } ?? 0)
        }
        return ordered.map(\.device)
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
        // Settings lists hidden devices in a group of their own, so a step
        // counts visible rows only. A hidden device keeps its saved place.
        let visible = devices.filter { !$0.isHidden }
        guard offset != 0, let from = visible.firstIndex(where: { $0.id == device.id }),
              offset > -visible.count, offset < visible.count, visible.indices.contains(from + offset),
              let index = devices.firstIndex(where: { $0.id == device.id }),
              let target = devices.firstIndex(where: { $0.id == visible[from + offset].id }) else { return false }
        var reordered = devices
        reordered.insert(reordered.remove(at: index), at: target)
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
        isInternal = try values.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false
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
        // A hold saved without this list gives way to any higher device that is connected.
        inputPassedOver = Set((try? values.decode([SavedValue<String>].self, forKey: .inputPassedOver))?.compactMap(\.value) ?? [])
        outputPassedOver = Set((try? values.decode([SavedValue<String>].self, forKey: .outputPassedOver))?.compactMap(\.value) ?? [])
        let savedLevels = (try? values.decode([String: SavedValue<Double>].self, forKey: .levelsBeforeMute)) ?? [:]
        levelsBeforeMute = savedLevels.compactMapValues { entry in
            guard let level = entry.value, (0...1).contains(level) else { return nil }
            return level
        }
    }
}

struct RoutePolicy {
    /// A device picked by hand, here or in macOS. It comes before the priority
    /// list until it disconnects or a device above it in the list connects.
    private(set) var heldID: String?
    /// The devices that were connected when the pick was made and have stayed
    /// connected. A higher device missing from this set has arrived since.
    private(set) var passedOver: Set<String>
    private var capturePassedOver = false
    private var connected: Set<String> = []
    private var previousUID: String?
    private var topologyChangedAt: TimeInterval?
    private var initialized = false
    private var awaitingInputFallback = false
    private var pendingSelection: (target: String, superseded: Set<String>, expires: TimeInterval)?

    init(heldID: String? = nil, passedOver: Set<String> = []) {
        self.heldID = heldID
        self.passedOver = heldID == nil ? [] : passedOver
    }

    mutating func release() {
        heldID = nil
        passedOver = []
        capturePassedOver = false
    }

    private mutating func hold(_ id: String, among present: Set<String>) {
        heldID = id
        passedOver = present
        capturePassedOver = false
    }

    mutating func desired(current: RouteDevice?, devices: [RouteDevice], rankedIDs: Set<String>,
                          time: TimeInterval) -> RouteDevice? {
        let live = devices.filter(\.isConnected)
        let present = Set(live.map(\.id))
        // HAL can publish connected devices before the default at login.
        // Preserve the saved choice until we can compare it with macOS.
        if !initialized, current == nil { return nil }
        // macOS moves the defaults by itself while devices come and go.
        if initialized, present != connected { topologyChangedAt = time }
        let settling = topologyChangedAt.map { time - $0 < 5 } ?? false
        let topRanked = live.first { rankedIDs.contains($0.id) && !$0.isHidden }
        if heldID.map(present.contains) == false {
            release()
            // Volatile snapshots may briefly have no default at all. Pin the
            // eventual replacement mic as soon as macOS publishes it.
            awaitingInputFallback = devices.first?.role == .input || devices.isEmpty
        }
        if awaitingInputFallback, let current {
            // The priority list picks the replacement when it has one. Without
            // one, keep the microphone macOS fell back to, so a headset that
            // reconnects later does not take over.
            if current.role == .input, !current.isHidden, topRanked == nil { hold(current.id, among: present) }
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
           connected.contains(current.id), !settling {
            hold(current.id, among: present)
        } else if !initialized, heldID != nil, let current, heldID != current.id {
            // An explicit choice made while the app wasn't running wins.
            hold(current.id, among: present)
        }
        // During handover macOS may temporarily have no default. Preserve
        // the last known device so a subsequent external pick is recognized.
        if let current { previousUID = current.id }
        connected = present
        initialized = true
        if capturePassedOver {
            passedOver = present
            capturePassedOver = false
        } else {
            passedOver.formIntersection(present)
        }
        // The devices are in priority order. A hand pick was made knowing the
        // higher ones in `passedOver`. One that connects later ends it.
        if let place = devices.firstIndex(where: { $0.id == heldID }),
           devices[..<place].contains(where: {
               $0.isConnected && !$0.isHidden && rankedIDs.contains($0.id) && !passedOver.contains($0.id)
           }) {
            release()
        }
        if let held = live.first(where: { $0.id == heldID }) { return held }
        if let topRanked { return topRanked }
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
        if manually {
            heldID = device.id
            // Filled in from the next device list, which is read right after the pick.
            passedOver = []
            capturePassedOver = true
        }
    }
}
