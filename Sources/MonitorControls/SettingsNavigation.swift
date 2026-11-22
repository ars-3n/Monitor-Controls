import AppKit
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

/// The two pages as tabs in the window's toolbar, like a preferences window.
@MainActor
final class SettingsTabs: NSObject, NSToolbarDelegate {
    private let navigation: SettingsNavigation
    let toolbar = NSToolbar(identifier: "MonitorControlsSettings")
    /// Titled with the page in view, as settings windows are.
    weak var window: NSWindow? { didSet { sync() } }

    init(navigation: SettingsNavigation) {
        self.navigation = navigation
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        sync()
    }

    /// Call after the section changes from outside the toolbar.
    func sync() {
        toolbar.selectedItemIdentifier = Self.identifier(navigation.section)
        window?.title = Self.title(navigation.section)
    }

    private static func title(_ section: SettingsSection) -> String { section == .devices ? "Devices" : "General" }

    private static func identifier(_ section: SettingsSection) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(section == .devices ? "devices" : "general")
    }

    private var identifiers: [NSToolbarItem.Identifier] { SettingsSection.allCases.map(Self.identifier) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = SettingsSection.allCases.first(where: { Self.identifier($0) == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = Self.title(section)
        item.image = NSImage(systemSymbolName: section == .devices ? "headphones" : "gearshape",
                             accessibilityDescription: nil)
        item.target = self
        item.action = #selector(select(_:))
        return item
    }

    @objc private func select(_ item: NSToolbarItem) {
        guard let section = SettingsSection.allCases.first(where: { Self.identifier($0) == item.itemIdentifier }) else { return }
        navigation.section = section
        sync()
    }
}
