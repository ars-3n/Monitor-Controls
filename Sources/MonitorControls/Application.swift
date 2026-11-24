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
    private lazy var settingsTabs = SettingsTabs(navigation: settingsNavigation)
    private var wakeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    /// When the panel last closed for a reason other than the icon's own action.
    /// macOS closes it on the way down of a press on the icon, and that press's
    /// action arrives a moment later and must not open it again.
    private var panelClosedAt: TimeInterval?
    private var closingFromIcon = false
    /// Where the panel's top left corner belongs while it is open.
    private var panelCorner: NSPoint?
    private var arrowHidden = false
    private var shownLevels = MenuBarLevels()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = status
        if let button = status.button {
            button.image = menuBarIcon(shownLevels)
            button.toolTip = "Monitor Controls"
            button.setAccessibilityLabel("Monitor Controls")
            button.action = #selector(togglePanel)
            button.target = self
            // Left presses act on the way down, like the system menus, so the action follows the close at once.
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            model.anchorIndicator(to: button)
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // The system's own menu-bar panels have no arrow. NSPopover has no
        // public switch for it. Use the private one only while it exists,
        // so a macOS without it shows the arrow again and nothing breaks.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
            popover.setValue(true, forKey: "shouldHideAnchor")
            arrowHidden = true
        }
        let menu = NSMenu()
        let root = NSMenuItem()
        root.submenu = makeAppMenu()
        menu.addItem(root)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        // Copy for the messages that can be selected. Nothing here is typed in.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized(_:)),
                                               name: NSWindow.didResizeNotification, object: nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.screenDidWake() }
        }
        model.start()
        followLevels()
        SymbolFit.shared.prepare(panelCircleSymbols(), scales: Set(NSScreen.screens.map(\.backingScaleFactor)))
    }

    /// Keeps the icon's knobs on the current brightness and volume.
    private func followLevels() {
        let levels = withObservationTracking { model.menuBarLevels.shown } onChange: { [weak self] in
            Task { @MainActor in self?.followLevels() }
        }
        guard levels != shownLevels else { return }
        shownLevels = levels
        item?.button?.image = menuBarIcon(levels)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshServices(checkLogin: settingsWindow?.isVisible == true)
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) { model.screenParametersChanged() }
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panelCorner = nil
        panelClosedAt = closingFromIcon ? nil : ProcessInfo.processInfo.systemUptime
        closingFromIcon = false
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
        let closed = panelClosedAt
        panelClosedAt = nil
        if popover.isShown {
            closingFromIcon = true
            popover.performClose(nil)
            if popover.isShown { popover.close() }
            closingFromIcon = false
        } else if let closed, ProcessInfo.processInfo.systemUptime - closed < 0.3 {
            // This press already closed the panel.
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = item?.button else { return }
        panelClosedAt = nil
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
            // Without the arrow the panel sits a little under the bar, like
            // the system's. Its window is larger than the panel it draws.
            var top = barBottom - 2
            var left = panel.frame.minX
            if arrowHidden, let content = popover.contentViewController?.view {
                let drawn = panel.convertToScreen(content.convert(content.bounds, to: nil))
                top = barBottom - 6 + (panel.frame.maxY - drawn.maxY)
                if screen == barWindow.screen {
                    // The panel ends at the icon's trailing edge and extends
                    // toward the middle of the bar. It moves over only to
                    // stay on the screen.
                    let margin = 8.0, area = screen.visibleFrame
                    let drawnLeft = max(area.minX + margin,
                                        min(buttonFrame.maxX - drawn.width, area.maxX - margin - drawn.width))
                    left = drawnLeft - (drawn.minX - panel.frame.minX)
                }
            }
            // On the bar's own screen the tip belongs right under it. The
            // system can also leave the panel too low: it places the panel
            // for one height, and the content then settles at another.
            if screen == barWindow.screen ? abs(panel.frame.maxY - top) > 0.5 : panel.frame.maxY > top {
                panel.setFrameTopLeftPoint(NSPoint(x: left, y: top))
            } else if abs(panel.frame.minX - left) > 0.5 {
                panel.setFrameTopLeftPoint(NSPoint(x: left, y: panel.frame.maxY))
            }
        }
        panelCorner = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.makeKey()
        watchOutsideClicks()
    }

    /// The panel changes height when a section comes or goes, such as the
    /// displays row once the search for displays ends. If its window keeps
    /// its bottom edge then, or centres itself again, put its corner back.
    @objc private func windowResized(_ notification: Notification) {
        guard popover.isShown, let panelCorner, let window = notification.object as? NSWindow,
              window === popover.contentViewController?.view.window,
              abs(window.frame.maxY - panelCorner.y) > 0.5 || abs(window.frame.minX - panelCorner.x) > 0.5 else { return }
        window.setFrameTopLeftPoint(panelCorner)
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
        guard popover.isShown else { return }
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
        settingsTabs.sync()
        if settingsWindow == nil {
            let initialSize = NSSize(width: 900, height: 540)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.toolbar = settingsTabs.toolbar
            settingsTabs.window = window
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SettingsView(model: model, navigation: settingsNavigation))
            // Let the window own its dimensions. Switching to a long device list
            // should scroll its content without resizing the user's window.
            host.sizingOptions = []
            window.contentViewController = host
            // Wide enough for the two device lists to stand side by side.
            window.contentMinSize = NSSize(width: 820, height: 420)
            window.setContentSize(initialSize)
            // A new name, so a frame saved for the narrower window is not restored.
            // Only the size is kept from the saved frame: the window is centred below.
            window.setFrameAutosaveName("MonitorControlsSettings")
            settingsWindow = window
        }
        // Opens in the middle of the screen every time. A window already on
        // screen stays where it was put.
        if let window = settingsWindow, !window.isVisible, !window.isMiniaturized,
           let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            // center() puts a window above the middle. This matches Window > Center.
            window.setFrameOrigin(NSPoint(x: (area.midX - window.frame.width / 2).rounded(),
                                          y: (area.midY - window.frame.height / 2).rounded()))
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
