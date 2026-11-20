import AppKit
import Darwin
import SwiftUI

@main
@MainActor
enum DeskControlsApp {
    static func main() {
        let id = Bundle.main.bundleIdentifier ?? "com.ars3n.DeskControls"
        let descriptor: Int32
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let path = support.appendingPathComponent(id + ".instance-lock").path
            // Open and lock atomically. Keep the file in place so every launch locks the same inode.
            descriptor = open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if descriptor == -1 {
                let code = errno
                if code == EWOULDBLOCK {
                    NSRunningApplication.runningApplications(withBundleIdentifier: id)
                        .first { !$0.isTerminated && $0.processIdentifier != getpid() }?.activate()
                    return
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        } catch {
            NSLog("Could not acquire the Desk Controls startup lock: %@", error.localizedDescription)
            return
        }
        defer { close(descriptor) }

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
    private lazy var contextMenu = makeAppMenu()
    private var settingsWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        if let button = status.button {
            button.image = soundLevelsIcon()
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
        let root = NSMenuItem()
        root.submenu = makeAppMenu()
        menu.addItem(root)
        NSApp.mainMenu = menu
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.screenDidWake() }
        }
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshServices() }
    func applicationDidChangeScreenParameters(_ notification: Notification) { model.screenParametersChanged() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window = settingsWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            showPanel()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        model.stop()
    }

    private func makeAppMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Desk Controls", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    @objc private func togglePanel() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = item?.button {
            popover.performClose(nil)
            NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
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
            if !window.setFrameUsingName("DeskControlsSettings") ||
                !NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: window.frame.midX, y: window.frame.maxY - 12)) }) {
                window.center()
            }
            settingsWindow = window
        }
        model.refreshServices()
        NSApp.activate()
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
