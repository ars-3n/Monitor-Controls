import AppKit
import Observation
import SwiftUI

/// The small brightness indicator shown when a key changes a monitor. macOS
/// shows its own only for displays it controls itself.
@MainActor
final class LevelOverlay {
    @MainActor @Observable
    final class Content {
        /// From 0 to 1.
        var brightness = 0.0
    }

    private static let size = NSSize(width: 252, height: 52)
    private static let visibleFor: Duration = .milliseconds(1300)

    private let content = Content()
    private var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    func show(brightness: Double, onScreen screenID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID
        }) else { return }
        content.brightness = brightness
        let panel = panel ?? makePanel()
        self.panel = panel

        // Below the menu bar at the trailing edge, where macOS puts its own.
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.maxX - Self.size.width - 12, y: area.maxY - Self.size.height - 10,
                              width: Self.size.width, height: Self.size.height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LevelOverlayView(content: content))
        return panel
    }
}

private struct LevelOverlayView: View {
    let content: LevelOverlay.Content

    var body: some View {
        let level = content.brightness
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 26)
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18))
                    Capsule().fill(.primary)
                        .frame(width: max(0, bar.size.width * level))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayGlass()
        .padding(4)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func overlayGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        }
    }
}
