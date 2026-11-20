import AppKit
import AudioRouting
import DisplayHardware
import SwiftUI

@MainActor
struct PanelView: View {
    let model: DeskModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Monitor Controls")
                    .font(DeskType.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    openSettings(.settings)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .font(DeskType.control)
                }
                .controlSize(.regular)
                .font(DeskType.control)
                .deskGlassButton()
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.bottom, 16)

            DisplaySection(controller: model.display)

            VStack(alignment: .leading, spacing: 14) {
                AudioChannel(model: model, input: false, openSettings: openSettings)
                Divider().padding(.leading, 52)
                AudioChannel(model: model, input: true, openSettings: openSettings)
            }
            .padding(.top, 18)

            if let message = model.statusMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(DeskType.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DisplaySection: View {
    let controller: DisplayController
    @State private var labels: [String: String] = [:]

    var body: some View {
        let displays = controller.displays
        Group {
            if displays.isEmpty {
                HStack(spacing: 14) {
                    MonitorGlyph(brightness: nil)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Display brightness").font(DeskType.device)
                        Text(controller.isRefreshing ? "Looking for displays…" : "Connect an external display to adjust its brightness.")
                            .font(DeskType.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            } else if displays.count > 2 {
                ScrollView {
                    displayRows(displays)
                }
                .frame(height: 204)
            } else {
                displayRows(displays)
            }
        }
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 16))
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(displays) { display in
                if display.id != displays.first?.id {
                    Divider().padding(.leading, 93)
                }
                let name = labels[display.id] ?? display.name
                HStack(spacing: 14) {
                    MonitorGlyph(brightness: display.brightness)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name)
                            .font(DeskType.device)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(name)
                            .accessibilityAddTraits(.isHeader)
                        if let value = display.brightness {
                            HStack {
                                Text("Brightness")
                                    .font(DeskType.body)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                LevelReadout(value: value)
                            }
                            NativeLevel(value: value, title: "Brightness for " + name) { newValue in
                                guard controller.displays.contains(where: {
                                    $0.id == display.id && $0.screenID == display.screenID && $0.brightness != nil
                                }) else { return }
                                controller.setBrightness(newValue, for: display.id)
                            }
                            .id(display.screenID)
                        } else {
                            Text(controller.isRefreshing ? "Reading brightness…" : "Brightness unavailable")
                                .font(DeskType.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
        return HStack(alignment: .center, spacing: 12) {
            MuteControl(input: input, muted: muteTarget == nil ? nil : muted) {
                guard let muteTarget, muteTarget == target(input: input, forMute: true),
                      let current = input ? audio.inputMuted : model.outputMuted else { return }
                if input { audio.setInputMuted(!current) } else { model.setOutputMuted(!current) }
            }
            .id(muteTarget)

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
                RoutePicker(audio: audio, input: input)
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
private struct RoutePicker: View {
    let audio: AudioController
    let input: Bool

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
            let selectedName = active.map { names[$0.id] ?? $0.name } ?? "Choose a device"
            let title = input ? "Choose microphone" : "Choose audio output"
            Menu {
                Picker(title, selection: Binding(
                    get: { active?.id },
                    set: { id in
                        let live = input ? audio.inputs : audio.outputs
                        guard let shown = available.first(where: { $0.id == id }),
                              let device = live.first(where: { $0.id == shown.id && $0.uid == shown.uid }),
                              device.isConnected, !device.isHidden else { return }
                        audio.select(device)
                    }
                )) {
                    if active == nil { Text("Choose a device").tag(String?.none).disabled(true) }
                    ForEach(available) { device in
                        Text(names[device.id] ?? device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .font(DeskType.body)
            } label: {
                Text(selectedName)
                    .font(DeskType.device)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(DeskType.device)
            .controlSize(.regular)
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(title)
            .accessibilityValue(selectedName)
            .help(title + " · " + selectedName)
        }
    }
}

private struct MuteControl: View {
    let input: Bool
    let muted: Bool?
    let toggle: () -> Void

    var body: some View {
        let liveSymbol = input ? "mic.fill" : "speaker.wave.2.fill"
        let muteSymbol = input ? "mic.slash.fill" : "speaker.slash.fill"
        let glyph = Image(systemName: muted == true ? muteSymbol : liveSymbol)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 28, height: 28)
        Group {
            if let muted {
                let action = (muted ? "Unmute " : "Mute ") + (input ? "microphone" : "output")
                Button(action: toggle) { glyph }
                    .buttonBorderShape(.circle)
                    .deskGlassButton()
                    .accessibilityLabel(action)
                    .accessibilityValue(muted ? "Muted" : "Unmuted")
                    .help(action)
            } else {
                glyph
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 40)
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

/// A live brightness swatch drawn inside a monitor silhouette. The slider and number
/// carry the same information when the swatch or its colors are hard to see.
private struct MonitorGlyph: View {
    let brightness: Double?

    var body: some View {
        Canvas { context, _ in
            let face = Path(roundedRect: CGRect(x: 1, y: 2, width: 62, height: 39), cornerRadius: 5)
            let screen = CGRect(x: 3.5, y: 4.5, width: 57, height: 34)
            let stand = Path(roundedRect: CGRect(x: 28.5, y: 39, width: 7, height: 9), cornerRadius: 1.5)
            let foot = Path(roundedRect: CGRect(x: 20, y: 47, width: 24, height: 2.5), cornerRadius: 1.25)
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
        .frame(width: 64, height: 52)
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

func routeLabels(for devices: [RouteDevice]) -> [String: String] {
    var labels: [String: String] = [:]
    for peers in Dictionary(grouping: devices, by: \.name).values where peers.count > 1 {
        for (index, peer) in peers.sorted(by: { $0.id < $1.id }).enumerated() {
            labels[peer.id] = "\(peer.name) (\(index + 1))"
        }
    }
    return labels
}
