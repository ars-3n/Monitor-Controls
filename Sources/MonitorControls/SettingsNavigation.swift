import Observation

enum SettingsDestination {
    case settings, monitorSpeakers
}

enum SettingsSection: CaseIterable {
    case general, devices
}

@MainActor @Observable
final class SettingsNavigation {
    var section = SettingsSection.general
    var pairingRequest = 0

    func open(_ destination: SettingsDestination) {
        if destination == .monitorSpeakers {
            section = .general
            pairingRequest += 1
        }
    }
}
