import AppKit
import Darwin
import SwiftUI

@main
@MainActor
enum MonitorControlsApp {
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
            NSLog("Could not acquire the Monitor Controls startup lock: %@", error.localizedDescription)
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
private final class DeskDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = DeskModel()
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private lazy var contextMenu = makeAppMenu()
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var wakeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = status
        if let button = status.button {
            button.image = soundLevelsIcon()
            button.toolTip = "Monitor Controls"
            button.setAccessibilityLabel("Monitor Controls")
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let menu = NSMenu()
        let root = NSMenuItem()
        root.submenu = makeAppMenu()
        menu.addItem(root)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.screenDidWake() }
        }
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshServices(checkLogin: settingsWindow?.isVisible == true)
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) { model.screenParametersChanged() }
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        model.closedPanel()
    }

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
        let quit = menu.addItem(withTitle: "Quit Monitor Controls", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: PanelView(model: model) { [weak self] destination in
                self?.openSettings(destination)
            })
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let panel = popover.contentViewController?.view.window else { return }
        if let screen = panel.screen, let barWindow = button.window {
            // The system popover can point into the icon itself. Keep the tip
            // below the visible menu bar, including when the bar auto-hides.
            let buttonFrame = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let barBottom = screen == barWindow.screen
                ? min(screen.visibleFrame.maxY, buttonFrame.minY) : screen.visibleFrame.maxY
            let top = barBottom - 2
            if panel.frame.maxY > top {
                panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
            }
        }
        panel.makeKey()
        watchOutsideClicks()
    }

    /// Once a device menu has been open in the panel, the popover stays up
    /// when focus moves elsewhere. Close it here in every case.
    @objc private func windowResignedKey(_ notification: Notification) {
        guard popover.isShown, let window = notification.object as? NSWindow,
              window === popover.contentViewController?.view.window,
              // An open device menu must not close the panel under it.
              RunLoop.current.currentMode != .eventTracking else { return }
        closePanel()
    }

    private func closePanel() {
        popover.performClose(nil)
        if popover.isShown { popover.close() }
    }

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        // Covers clicks that leave the panel focused, such as on the menu bar.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    @objc private func showSettings() {
        openSettings(.settings)
    }

    private func openSettings(_ destination: SettingsDestination) {
        popover.performClose(nil)
        settingsNavigation.open(destination)
        if settingsWindow == nil {
            let initialSize = NSSize(width: 900, height: 540)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Monitor Controls Settings"
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SettingsView(model: model, navigation: settingsNavigation))
            // Let the split view put the section name and its toolbar in the title bar.
            host.sceneBridgingOptions = [.title, .toolbars]
            // Let the window own its dimensions. Switching to a long device list
            // should scroll its content without resizing the user's window.
            host.sizingOptions = []
            window.contentViewController = host
            // Wide enough for the two device lists to stand side by side.
            window.contentMinSize = NSSize(width: 820, height: 420)
            window.setContentSize(initialSize)
            // A new name, so a frame saved for the narrower window is not restored.
            window.setFrameAutosaveName("MonitorControlsSettings")
            if !window.setFrameUsingName("MonitorControlsSettings") ||
                !NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: window.frame.midX, y: window.frame.maxY - 12)) }) {
                window.center()
            }
            settingsWindow = window
        }
        model.audio.refresh()
        model.refreshServices()
        // A menu-bar app is rarely the active one. macOS declines the plain
        // activate() request there and leaves the window behind the app in use.
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Keeps the window in view if a later macOS declines this call too.
        settingsWindow?.orderFrontRegardless()
    }
}
