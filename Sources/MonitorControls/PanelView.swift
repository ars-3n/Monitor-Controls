import AppKit
import AudioRouting
import DeskPolicy
import DisplayHardware
import SwiftUI

@MainActor
struct PanelView: View {
    let model: DeskModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Monitor Controls")
                    .font(DeskType.heading)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    openSettings(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonBorderShape(.circle)
                .deskGlassButton()
                .accessibilityLabel("Settings…")
                .help("Settings…")
                .keyboardShortcut(",", modifiers: .command)
            }

            // Without an external display there is nothing to adjust, so the section
            // is left out once the search for displays has ended.
            if !model.display.displays.isEmpty || model.display.isRefreshing {
                DisplaySection(controller: model.display)
                Divider().padding(.leading, PanelMetrics.textInset)
            }
            AudioChannel(model: model, input: false, openSettings: openSettings)
            Divider().padding(.leading, PanelMetrics.textInset)
            AudioChannel(model: model, input: true, openSettings: openSettings)

            if let message = model.statusMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(DeskType.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every row has the same two columns: a symbol, then its text and slider.
private enum PanelMetrics {
    static let symbolColumn: CGFloat = 40
    static let columnSpacing: CGFloat = 12
    static let textInset = symbolColumn + columnSpacing
}

/// A symbol that only labels its row. Buttons in the same column use glass.
private struct RowSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: PanelMetrics.symbolColumn, height: 28)
            .accessibilityHidden(true)
    }
}

private struct DisplaySection: View {
    let controller: DisplayController
    @State private var labels: [String: String] = [:]

    var body: some View {
        let displays = controller.displays
        Group {
            if displays.isEmpty {
                HStack(spacing: PanelMetrics.columnSpacing) {
                    MonitorGlyph(brightness: nil)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brightness")
                            .font(DeskType.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Looking for displays…")
                            .font(DeskType.body)
                    }
                    Spacer(minLength: 0)
                }
            } else if displays.count > 2 {
                ScrollView {
                    displayRows(displays)
                }
                .frame(height: 200)
            } else {
                displayRows(displays)
            }
        }
        .onChange(of: displays.map(DisplayIdentity.init), initial: true) {
            labels = displayLabels(for: controller.displays)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            labels = displayLabels(for: controller.displays)
        }
    }

    /// Levels can change on every drag event. Only identity, order, and physical
    /// arrangement affect the names of identical monitors.
    private struct DisplayIdentity: Equatable {
        let id: String
        let screenID: CGDirectDisplayID
        let name: String

        init(_ display: MonitorDisplay) {
            id = display.id
            screenID = display.screenID
            name = display.name
        }
    }

    private func displayRows(_ displays: [MonitorDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(displays) { display in
                if display.id != displays.first?.id {
                    Divider().padding(.leading, PanelMetrics.textInset)
                }
                let name = labels[display.id] ?? display.name
                HStack(alignment: .center, spacing: PanelMetrics.columnSpacing) {
                    MonitorGlyph(brightness: display.brightness)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brightness")
                            .font(DeskType.body.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(DeskType.device)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(name)
                            .accessibilityAddTraits(.isHeader)
                        if let value = display.brightness {
                            HStack(spacing: 12) {
                                NativeLevel(value: value, title: "Brightness for " + name) { newValue in
                                    guard controller.displays.contains(where: {
                                        $0.id == display.id && $0.screenID == display.screenID && $0.brightness != nil
                                    }) else { return }
                                    controller.setBrightness(newValue, for: display.id)
                                }
                                .id(display.screenID)
                                LevelReadout(value: value)
                            }
                        } else {
                            Text(controller.isRefreshing ? "Reading brightness…" : "Brightness unavailable")
                                .font(DeskType.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct AudioChannel: View {
    let model: DeskModel
    let input: Bool
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        let audio = model.audio
        let active = input ? audio.input : audio.output
        let role = input ? "Microphone" : "Output"
        let muted = input ? audio.inputMuted : model.outputMuted
        let level = input ? audio.inputGain : model.volume
        let levelTarget = target(input: input, forMute: false)
        let muteTarget = target(input: input, forMute: true)
        let needsPairing = !input && active?.isDisplay == true
            && ((level == nil && model.display.displays.contains { $0.volume != nil })
                || (muted == nil && model.display.displays.contains { $0.muted != nil }))
        // The device list hangs below, so the button lines up with the title and slider.
        return HStack(alignment: .top, spacing: PanelMetrics.columnSpacing) {
            MuteControl(input: input, muted: muteTarget == nil ? nil : muted) {
                guard let muteTarget, muteTarget == target(input: input, forMute: true),
                      let current = input ? audio.inputMuted : model.outputMuted else { return }
                if input { audio.setInputMuted(!current) } else { model.setOutputMuted(!current) }
            }
            .id(muteTarget)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(role)
                        .font(DeskType.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if muteTarget != nil && muted == true {
                        Text("Muted")
                            .font(DeskType.body.weight(.medium))
                    }
                }
                if active != nil {
                    if let level {
                        HStack(spacing: 12) {
                            NativeLevel(value: level, title: input ? "Microphone gain" : "Output volume") { newValue in
                                guard let levelTarget, levelTarget == target(input: input, forMute: false) else { return }
                                if input { audio.setInputGain(newValue) } else { model.setVolume(newValue) }
                            }
                            .id(levelTarget)
                            LevelReadout(value: level)
                        }
                    }
                    if needsPairing {
                        Button("Choose a monitor for these speakers…") { openSettings(.monitorSpeakers) }
                            .buttonStyle(.link)
                            .font(DeskType.body)
                    } else if level == nil {
                        Text(input ? "Gain unavailable" : "Volume unavailable")
                            .font(DeskType.body)
                            .foregroundStyle(.secondary)
                    }
                }
                RouteList(model: model, input: input)
                    .padding(.top, 2)
            }
        }
    }

    /// Native controls can finish a drag or press after the system switches
    /// devices. Bind each action to the live endpoint and its control path.
    private func target(input: Bool, forMute: Bool) -> LevelTarget? {
        let audio = model.audio
        guard let route = input ? audio.input : audio.output else { return nil }
        if input {
            guard forMute ? audio.inputMuted != nil : audio.inputGain != nil else { return nil }
            return LevelTarget(uid: route.uid)
        }
        if forMute ? audio.outputMuted != nil : audio.outputVolume != nil {
            return LevelTarget(uid: route.uid)
        }
        guard let id = model.resolvedDisplayID, let monitor = model.display.displays.first(where: { $0.id == id }),
              forMute ? monitor.muted != nil : monitor.volume != nil else { return nil }
        return LevelTarget(uid: route.uid, displayID: id, screenID: monitor.screenID)
    }

    private struct LevelTarget: Hashable {
        let uid: String
        var displayID: String?
        var screenID: CGDirectDisplayID?
    }
}

/// Keep inventory observation separate so dragging a fader doesn't rebuild an open device menu.
private struct RouteList: View {
    let model: DeskModel
    let input: Bool
    private var audio: AudioController { model.audio }

    /// Devices listed in the panel. The rest are behind "Show all".
    private static let listed = 3

    var body: some View {
        let active = input ? audio.input : audio.output
        let devices = input ? audio.inputs : audio.outputs
        let available = devices.filter { $0.isConnected && (!$0.isHidden || $0.id == active?.id) }
        if available.isEmpty {
            Text(input ? "No microphone available" : "No output available")
                .font(DeskType.body)
                .foregroundStyle(.secondary)
        } else {
            let names = routeLabels(for: devices)
            let listed = shortlist(available.map(\.id), active: active?.id, limit: Self.listed)
            let title = input ? "Choose microphone" : "Choose audio output"
            VStack(alignment: .leading, spacing: 1) {
                ForEach(available.filter { listed.contains($0.id) }) { device in
                    let idle = input ? nil : audio.idleSpeakers.flatMap { $0.uid == device.uid ? $0 : nil }
                    // The device in use shows its mute on its own row too, like the idle speakers.
                    let inUse = device.id != active?.id ? nil : input ? audio.inputMuted : model.outputMuted
                    RouteRow(name: names[device.id] ?? device.name, symbol: routeSymbol(for: device),
                             selected: device.id == active?.id, input: input,
                             mute: idle.map { speakers in
                                 RouteRow.Mute(muted: speakers.muted) {
                                     guard audio.idleSpeakers?.uid == speakers.uid else { return }
                                     audio.setIdleSpeakersMuted(!speakers.muted)
                                 }
                             } ?? inUse.map { muted in
                                 RouteRow.Mute(muted: muted) {
                                     if input {
                                         guard audio.input?.uid == device.uid, audio.inputMuted == muted else { return }
                                         audio.setInputMuted(!muted)
                                     } else {
                                         guard audio.output?.uid == device.uid, model.outputMuted == muted else { return }
                                         model.setOutputMuted(!muted)
                                     }
                                 }
                             }) {
                        select(device.id, among: available)
                    }
                }
                if available.count > listed.count {
                    Menu {
                        Picker(title, selection: Binding(get: { active?.id }, set: { select($0, among: available) })) {
                            if active == nil { Text("Choose a device").tag(String?.none).disabled(true) }
                            ForEach(available) { device in
                                Text(names[device.id] ?? device.name).tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .font(DeskType.body)
                    } label: {
                        RouteRowLabel(name: "Show all", symbol: "ellipsis", selected: false)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(title)
                    .help(title)
                }
            }
            // The row highlight extends past the text, which stays on the column's edge.
            .padding(.horizontal, -RouteRowLabel.inset)
        }
    }

    private func select(_ id: String?, among available: [RouteDevice]) {
        let live = input ? audio.inputs : audio.outputs
        guard let shown = available.first(where: { $0.id == id }),
              let device = live.first(where: { $0.id == shown.id && $0.uid == shown.uid }),
              device.isConnected, !device.isHidden else { return }
        audio.select(device)
    }
}

private struct RouteRow: View {
    let name: String
    let symbol: String
    let selected: Bool
    let input: Bool
    var mute: Mute?
    let choose: () -> Void

    /// The mute of the device in use, or of the Mac's speakers while they are idle.
    struct Mute {
        let muted: Bool
        let toggle: () -> Void
    }

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: choose) {
                RouteRowLabel(name: name, symbol: symbol, selected: selected)
                    // The name stops short of the mute button.
                    .padding(.trailing, mute == nil ? 0 : 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(hovered && !selected ? 0.08 : 0)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(selected ? name : "Use \(name) as the \(input ? "microphone" : "output")")

            if let mute {
                let action = (mute.muted ? "Unmute " : "Mute ") + name
                Button(action: mute.toggle) {
                    CenteredSymbol(name: input ? (mute.muted ? "mic.slash.fill" : "mic.fill")
                                       : (mute.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
                                   pointSize: 11, weight: .semibold, side: 22)
                        .foregroundStyle(mute.muted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(Circle().fill(mute.muted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary.opacity(0.1))))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, RouteRowLabel.inset)
                // Out of the way until the pointer is on the row. A muted device keeps it in view.
                .opacity(hovered || mute.muted ? 1 : 0)
                .accessibilityLabel(action)
                .accessibilityValue(mute.muted ? "Muted" : "Unmuted")
                .help(action)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// The symbols the panel puts in circles, so their centered sizes can be found at launch.
@MainActor
func panelCircleSymbols() -> [CenteredSymbol] {
    let devices = ["display", "airpodsmax", "airpodspro", "airpods", "laptopcomputer", "iphone", "headphones", "mic", "hifispeaker", "ellipsis"]
    let mutes = ["mic.fill", "mic.slash.fill", "speaker.wave.2.fill", "speaker.slash.fill"]
    return (devices + mutes).map { CenteredSymbol(name: $0, pointSize: 11, weight: .semibold, side: 22) }
        + mutes.map { CenteredSymbol(name: $0, pointSize: 16, weight: .medium, side: 28) }
}

private struct RouteRowLabel: View {
    static let inset: CGFloat = 7

    let name: String
    let symbol: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The active device has its icon on the accent color, as in Control Center.
            CenteredSymbol(name: symbol, pointSize: 11, weight: .semibold, side: 22)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(Circle().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.1))))
                .accessibilityHidden(true)
            Text(name)
                .font(selected ? DeskType.control : DeskType.body)
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, Self.inset)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

private struct MuteControl: View {
    let input: Bool
    let muted: Bool?
    let toggle: () -> Void

    var body: some View {
        let liveSymbol = input ? "mic.fill" : "speaker.wave.2.fill"
        let muteSymbol = input ? "mic.slash.fill" : "speaker.slash.fill"
        let glyph = CenteredSymbol(name: muted == true ? muteSymbol : liveSymbol, pointSize: 16, weight: .medium, side: 28)
        Group {
            if let muted {
                let action = (muted ? "Unmute " : "Mute ") + (input ? "microphone" : "output")
                Button(action: toggle) { glyph }
                    .buttonBorderShape(.circle)
                    // A muted device is easy to forget, so its button is red like the one in a call.
                    .deskGlassButton(filled: muted ? .red : nil)
                    .accessibilityLabel(action)
                    .accessibilityValue(muted ? "Muted" : "Unmuted")
                    .help(action)
            } else {
                glyph
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: PanelMetrics.symbolColumn)
    }
}

private struct NativeLevel: View {
    let value: Double
    let title: String
    let setValue: @MainActor (Double) -> Void

    var body: some View {
        Slider(value: Binding(get: { value }, set: { setValue($0) }), in: 0...1) {
            Text(title)
        }
        .labelsHidden()
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}

private struct LevelReadout: View {
    let value: Double

    var body: some View {
        Text(value, format: .percent.precision(.fractionLength(0)))
            .font(DeskType.control.monospacedDigit())
            .frame(minWidth: 35, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

/// A small monitor whose screen lightens with the display's brightness.
private struct MonitorGlyph: View {
    let brightness: Double?

    /// The drawing below is laid out on a 64 by 52 grid.
    private static let scale = PanelMetrics.symbolColumn / 64

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: Self.scale, y: Self.scale)
            let face = Path(roundedRect: CGRect(x: 1, y: 2, width: 62, height: 39), cornerRadius: 6)
            let screen = CGRect(x: 4, y: 5, width: 56, height: 33)
            let stand = Path(roundedRect: CGRect(x: 28.5, y: 39, width: 7, height: 9), cornerRadius: 1.5)
            let foot = Path(roundedRect: CGRect(x: 20, y: 47, width: 24, height: 3), cornerRadius: 1.5)
            context.fill(stand, with: .color(.secondary))
            context.fill(foot, with: .color(.secondary))
            context.fill(face, with: .color(Color(white: 0.20)))
            var glass = context
            glass.clip(to: Path(roundedRect: screen, cornerRadius: 3))
            glass.fill(Path(screen), with: .color(Color(white: 0.16)))
            if let brightness {
                // A dark-to-light sweep stays recognizable from minimum to maximum brightness.
                let luminance = min(1, max(0, brightness))
                glass.opacity = 0.25 + 0.75 * luminance
                glass.fill(Path(screen), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.05, green: 0.27, blue: 0.32),
                                      Color(red: 0.43, green: 0.85, blue: 0.73)]),
                    startPoint: CGPoint(x: 5, y: 29), endPoint: CGPoint(x: 58, y: 10)
                ))
                var ridge = Path()
                ridge.move(to: CGPoint(x: 2, y: 39))
                ridge.addQuadCurve(to: CGPoint(x: 62, y: 6), control: CGPoint(x: 32, y: 42))
                ridge.addLine(to: CGPoint(x: 62, y: 40))
                ridge.closeSubpath()
                glass.fill(ridge, with: .color(.white.opacity(0.34)))
            }
        }
        .frame(width: PanelMetrics.symbolColumn, height: 52 * Self.scale)
        .accessibilityHidden(true)
    }
}

/// Add a physical location when identical model names would produce indistinguishable sliders.
@MainActor
func displayLabels(for displays: [MonitorDisplay]) -> [String: String] {
    let duplicates = Dictionary(grouping: displays, by: \.name).values.filter { $0.count > 1 }
    guard !duplicates.isEmpty else { return [:] }
    let frames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return (number.uint32Value, screen.frame)
    })
    var labels: [String: String] = [:]
    for peers in duplicates {
        if peers.count == 2, let a = frames[peers[0].screenID], let b = frames[peers[1].screenID], a.midX != b.midX || a.midY != b.midY {
            let vertical = abs(a.midY - b.midY) > abs(a.midX - b.midX)
            let suffixes = vertical
                ? (a.midY > b.midY ? ["upper", "lower"] : ["lower", "upper"])
                : (a.midX < b.midX ? ["left", "right"] : ["right", "left"])
            for (peer, suffix) in zip(peers, suffixes) { labels[peer.id] = "\(peer.name) (\(suffix))" }
        } else {
            for (i, peer) in peers.enumerated() { labels[peer.id] = "\(peer.name) (\(i + 1))" }
        }
    }
    return labels
}

/// Core Audio has no icon for a device, so beyond monitors the name decides.
func routeSymbol(for device: RouteDevice) -> String {
    if device.isDisplay { return "display" }
    let name = device.name.lowercased()
    if name.contains("airpods max") { return "airpodsmax" }
    if name.contains("airpods") { return name.contains("pro") ? "airpodspro" : "airpods" }
    if name.contains("macbook") { return "laptopcomputer" }
    if name.contains("iphone") { return "iphone" }
    if name.contains("headphone") || name.contains("headset") { return "headphones" }
    return device.role == .input ? "mic" : "hifispeaker"
}

func routeLabels(for devices: [RouteDevice]) -> [String: String] {
    var labels: [String: String] = [:]
    for peers in Dictionary(grouping: devices, by: \.name).values where peers.count > 1 {
        for (index, peer) in peers.sorted(by: { $0.id < $1.id }).enumerated() {
            labels[peer.id] = "\(peer.name) (\(index + 1))"
        }
    }
    return labels
}
