import AppKit
import SwiftUI

@main
@MainActor
enum DeskControlsApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = DeskDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class DeskDelegate: NSObject, NSApplicationDelegate {
    private let model = DeskModel()
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening the bundle again should reveal the existing instance.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        if let button = status.button {
            let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Desk Controls")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Desk Controls"
            button.setAccessibilityLabel("Desk Controls")
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model) { [weak self] in
            self?.showSettings()
        })
        let menu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Desk Controls", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshServices() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showPanel() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp, let status = item, let menu = NSApp.mainMenu?.items.first?.submenu {
            status.menu = menu
            status.button?.performClick(nil)
            status.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = item?.button else { return }
        model.openedPanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 465),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Desk Controls Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 475, height: 390)
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setFrameAutosaveName("DeskControlsSettings")
            if !window.setFrameUsingName("DeskControlsSettings") { window.center() }
            settingsWindow = window
        }
        model.refreshServices()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
