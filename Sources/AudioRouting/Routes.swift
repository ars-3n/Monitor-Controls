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

/// The Mac's own speakers while another output is in use. Sounds that ignore
/// the output choice still play there, so they have a mute of their own.
public struct IdleSpeakers: Equatable, Sendable {
    public let uid: String
    public let muted: Bool
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
    /// The USB vendor and product of a device without a serial number. Two
    /// models can share a name, and this tells them apart on any port.
    var model: String?
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
    var model: String?
    /// Set when another model was already remembered under the same UID.
    var key: String?
    /// Higher for the port a device of this kind was last used on.
    var seen = 0

    /// What the saved order lists this record as.
    var orderKey: String { key ?? uid }

    init(_ endpoint: Endpoint) {
        uid = endpoint.uid
        name = endpoint.name
        role = endpoint.role
        isDisplay = endpoint.isDisplay
        isVirtual = endpoint.isVirtual
        isInternal = endpoint.isInternal
        followsPort = endpoint.followsPort
        model = endpoint.model
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

    /// The record for a connected device. One saved before models were read
    /// belongs to the first model that turns up under its UID.
    private func index(for endpoint: Endpoint) -> Int? {
        let candidates = records.indices.filter { records[$0].role == endpoint.role && records[$0].uid == endpoint.uid }
        if let exact = candidates.first(where: { records[$0].model == endpoint.model }) { return exact }
        return endpoint.model == nil ? candidates.first : candidates.first { records[$0].model == nil }
    }

    mutating func remember(_ endpoints: [Endpoint]) {
        var portsByFamily: [String: [String?: Set<String>]] = [:]
        var present: [Int] = []
        var added: Set<Int> = []
        for endpoint in endpoints {
            var followsPort = endpoint.followsPort
            if let i = index(for: endpoint) {
                records[i].name = endpoint.name
                records[i].isDisplay = endpoint.isDisplay
                records[i].isVirtual = endpoint.isVirtual
                records[i].isInternal = endpoint.isInternal
                if let confirmed = followsPort { records[i].followsPort = confirmed }
                if let model = endpoint.model { records[i].model = model }
                followsPort = records[i].followsPort
                present.append(i)
            } else {
                var record = RememberedRoute(endpoint)
                if let model = endpoint.model, records.contains(where: { $0.role == endpoint.role && $0.uid == endpoint.uid }) {
                    record.key = endpoint.uid + "#" + model
                }
                records.append(record)
                present.append(records.count - 1)
                added.insert(records.count - 1)
            }
            if followsPort == true, let port = PortIdentity(endpoint.uid) {
                portsByFamily[port.family, default: [:]][endpoint.model, default: []].insert(port.port)
            }
        }
        for (family, ports) in portsByFamily {
            // Without a model for each of them, the name is all there is to compare.
            if ports[nil] != nil {
                if ports.values.reduce(into: Set<String>(), { $0.formUnion($1) }).count > 1 { ambiguousFamilies.insert(family) }
                continue
            }
            for (model, ports) in ports where ports.count > 1 {
                ambiguousFamilies.insert(family)
                if let model { ambiguousFamilies.insert(family + "#" + model) }
            }
        }
        let models = knownModels
        for i in present {
            guard let mine = kin(records[i], models) else { continue }
            let twins = records.indices.filter { other in
                other != i && records[other].role == records[i].role && kin(records[other], models).map { $0 == mine } == true
            }
            let away = twins.filter { !present.contains($0) }
            if added.contains(i), ambiguousFamilies.contains(mine.family) { place(i, beside: twins, away: away) }
            // Keep the port in use ahead of the ones its twins were left on.
            if let rival = away.map({ records[$0].seen }).max(), rival >= records[i].seen {
                records[i].seen = max(rival, twins.map { records[$0].seen }.max() ?? 0) + 1
            }
        }
    }

    /// Identical devices are told apart by port, so one on a port it has never
    /// used cannot be recognised. It is most likely the twin that is away and
    /// was used last, and takes that one's place and visibility.
    private mutating func place(_ i: Int, beside twins: [Int], away: [Int]) {
        let role = records[i].role
        var order = order(for: role)
        guard !order.contains(records[i].orderKey) else { return }
        let likely = away.max { (records[$0].seen, $0) < (records[$1].seen, $1) }
        if let likely {
            records[i].hidden = records[likely].hidden
            records[i].hiddenRevision = records[likely].hiddenRevision
        }
        if let likely, let at = order.firstIndex(of: records[likely].orderKey) {
            order.insert(records[i].orderKey, at: at)
        } else if let last = twins.filter({ !away.contains($0) }).compactMap({ order.firstIndex(of: records[$0].orderKey) }).max() {
            order.insert(records[i].orderKey, at: last + 1)
        } else {
            return
        }
        setOrder(order, for: role)
    }

    /// The models seen under each family name.
    private var knownModels: [String: Set<String>] {
        var models: [String: Set<String>] = [:]
        for record in records where record.followsPort == true {
            guard let model = record.model, let port = PortIdentity(record.uid) else { continue }
            models[port.family, default: []].insert(model)
        }
        return models
    }

    /// The devices a record cannot be told apart from by anything but its port.
    /// The model only counts once a second one has shown up under the name.
    private func kin(_ record: RememberedRoute, _ models: [String: Set<String>]) -> (family: String, endpoint: String)? {
        guard record.followsPort == true, let port = PortIdentity(record.uid) else { return nil }
        if let model = record.model, models[port.family, default: []].count > 1 {
            return (port.family + "#" + model, port.endpoint)
        }
        return (port.family, port.endpoint)
    }

    private func identifier(_ record: RememberedRoute, _ models: [String: Set<String>]) -> String {
        let role = record.role.rawValue
        if let kin = kin(record, models), !ambiguousFamilies.contains(kin.family) {
            return "\(role):port:\(kin.family):\(kin.endpoint)"
        }
        return "\(role):uid:\(record.orderKey)"
    }

    private func groups(_ role: RouteRole) -> [String: [Int]] {
        let models = knownModels
        return Dictionary(grouping: records.indices.filter { records[$0].role == role }) { identifier(records[$0], models) }
    }

    /// The devices in priority order. This is the order Settings shows and
    /// the order automatic switching follows.
    func devices(_ endpoints: [Endpoint], role: RouteRole) -> [RouteDevice] {
        // Coalesce ports only while the evidence supports it. Keep original
        // per-port settings intact so discovering two identical devices can
        // immediately restore each one's own visibility and priority.
        let groups = groups(role)
        let ranks = Dictionary(order(for: role).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let connected = Set(endpoints.filter { $0.role == role }.compactMap { index(for: $0) })
        let rows = groups.map { id, indices in
            let group = indices.map { records[$0] }
            let current = indices.first { connected.contains($0) }.map { records[$0] }
            let record = current ?? group.last!
            let visibility = group.filter { $0.hidden != nil }.max { $0.hiddenRevision < $1.hiddenRevision }
            return (device: RouteDevice(id: id, uid: record.uid, name: record.name, role: role, isDisplay: record.isDisplay,
                                        isHidden: visibility?.hidden ?? false, isConnected: current != nil, isVirtual: record.isVirtual),
                    rank: group.compactMap { ranks[$0.orderKey] }.min(),
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
        guard let i = groups(device.role)[device.id]?.first(where: { records[$0].uid == device.uid }) else { return }
        let revision = (records.map(\.hiddenRevision).max() ?? 0) + 1
        records[i].hidden = value
        records[i].hiddenRevision = revision
    }

    /// Drops everything saved for a device, including the other ports it was
    /// seen on. It gets a new row with default settings if it connects again.
    mutating func forget(_ device: RouteDevice) {
        let indices = Set(groups(device.role)[device.id] ?? [])
        guard !indices.isEmpty else { return }
        let aliases = Set(indices.map { records[$0].orderKey })
        records = records.indices.filter { !indices.contains($0) }.map { records[$0] }
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
        let groups = groups(device.role)
        var updated: [String] = []
        for row in reordered {
            let group = groups[row.id, default: []].map { records[$0] }
            let key = group.first { $0.uid == row.uid }?.orderKey ?? row.uid
            updated.append(key)
            let aliases = Set(group.map(\.orderKey)).subtracting([key])
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
        model = try? values.decodeIfPresent(String.self, forKey: .model)
        key = try? values.decodeIfPresent(String.self, forKey: .key)
        seen = (try? values.decodeIfPresent(Int.self, forKey: .seen)) ?? 0
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
