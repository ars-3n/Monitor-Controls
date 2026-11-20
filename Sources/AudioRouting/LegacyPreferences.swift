import Foundation

private struct LegacyDevice: Decodable {
    let uid: String
    let name: String
    let isInput: Bool
    let followsPortChanges: Bool?
    let declaredCategory: String?
    let previousUIDs: [String]?
}

extension RoutePreferences {
    static func containsLegacyChoices(_ domain: [String: Any]) -> Bool {
        ["inputPriorities", "speakerPriorities", "headphonePriorities", "hiddenMics", "hiddenSpeakers", "hiddenHeadphones"].contains {
            !(domain[$0] as? [String] ?? []).isEmpty
        }
    }

    mutating func importLegacy(_ domain: [String: Any]) -> Bool {
        guard !importedLegacy, Self.containsLegacyChoices(domain) else { return false }
        func strings(_ key: String) -> [String] { domain[key] as? [String] ?? [] }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let displays = Set(strings("displayDefaultsApplied"))
        let categories = domain["deviceCategories"] as? [String: String] ?? [:]
        let excludedInputs = Set(strings("neverUseInputs") + strings("neverUseDevices"))
        let excludedOutputs = Set(strings("neverUseOutputs") + strings("neverUseDevices"))
        let inputRanks = strings("inputPriorities").filter { !excludedInputs.contains($0) }
        // Legacy ranks speakers and headphones separately. Headphones first
        // preserves the fork's preference when both groups are connected.
        let outputRanks = (strings("headphonePriorities") + strings("speakerPriorities")).filter { !excludedOutputs.contains($0) }
        let microphones = Set(strings("hiddenMics"))
        let speakers = Set(strings("hiddenSpeakers"))
        let headphones = Set(strings("hiddenHeadphones"))
        let known = (domain["knownDevices"] as? Data).flatMap { try? JSONDecoder().decode([LegacyDevice].self, from: $0) } ?? []
        ambiguousFamilies.formUnion(strings("ambiguousPortFamilies"))
        var legacyNames: [RouteRole: [String: LegacyDevice]] = [:]
        for record in known {
            let role: RouteRole = record.isInput ? .input : .output
            for uid in [record.uid] + (record.previousUIDs ?? []) {
                legacyNames[role, default: [:]][uid] = record
            }
        }
        for role in RouteRole.allCases {
            let legacy = legacyNames[role, default: [:]]
            let ranks = role == .input ? inputRanks : outputRanks
            let hidden = role == .input ? microphones : speakers.union(headphones)
            let relevant = Set(ranks).union(hidden).union(legacy.keys)
            // Set each alias's state from its canonical legacy row. A missing
            // alias in an old hidden list does not mean it was explicitly shown.
            var revision = records.map(\.hiddenRevision).max() ?? 0
            for uid in relevant.sorted() {
                let metadata = legacy[uid]
                let current = records.firstIndex { $0.uid == uid && $0.role == role }
                let display = displays.contains(uid) || metadata.map { displays.contains($0.uid) } == true
                var record = current.map { records[$0] } ?? RememberedRoute(Endpoint(objectID: 0, uid: uid, name: metadata?.name ?? uid,
                                                                                     role: role, isDisplay: display))
                if record.followsPort != true, current == nil || record.followsPort == nil {
                    record.followsPort = metadata?.followsPortChanges ?? (display ? true : nil)
                }
                let canonical = metadata?.uid ?? uid
                let category = categories[canonical] ?? metadata?.declaredCategory
                if role == .output, let category {
                    record.hidden = (category == "headphone" ? headphones : speakers).contains(canonical)
                } else {
                    record.hidden = hidden.contains(canonical)
                }
                revision += 1
                record.hiddenRevision = revision
                if let current { records[current] = record } else { records.append(record) }
            }
            setOrder(unique(ranks + order(for: role)), for: role)
        }
        importedLegacy = true
        return true
    }
}
