import Observation

enum SettingsDestination {
    case settings, monitorSpeakers
}

enum SettingsSection: CaseIterable {
    case devices, general
}

@MainActor @Observable
final class SettingsNavigation {
    var section = SettingsSection.devices
    var pairingRequest = 0

    func open(_ destination: SettingsDestination) {
        if destination == .monitorSpeakers {
            section = .general
            pairingRequest += 1
        }
    }
}
