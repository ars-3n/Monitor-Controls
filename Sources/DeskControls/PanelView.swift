import AppKit
import AudioRouting
import DisplayHardware
import SwiftUI

@MainActor
struct PanelView: View {
    let model: DeskModel
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Desk Controls")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .controlSize(.small)
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 15) {
                brightness
                Divider()
                audioRow(input: false)
                Divider()
                audioRow(input: true)
                if let message = model.statusMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brightness")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.display.displays.isEmpty {
                Text(model.display.isRefreshing ? "Looking for displays…" : "Connect an external display to adjust its brightness.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.display.displays.count > 3 {
                ScrollView {
                    brightnessRows
                        .padding(.horizontal, 2)
                }
                .frame(height: 150)
            } else {
                brightnessRows
            }
        }
    }

    private var brightnessRows: some View {
        let names = displayLabels(for: model.display.displays)
        return VStack(alignment: .leading, spacing: 11) {
            ForEach(model.display.displays) { display in
                let name = names[display.id] ?? display.name
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)
                    LevelControl(
                        title: "Brightness for " + name,
                        symbol: "sun.max",
                        value: display.brightness,
                        unavailable: model.display.isRefreshing ? "Reading brightness…" : "Brightness unavailable",
                        setValue: { value in
                            guard model.display.displays.contains(where: {
                                $0.id == display.id && $0.screenID == display.screenID && $0.brightness != nil
                            }) else { return }
                            model.display.setBrightness(value, for: display.id)
                        }
                    )
                    .id(display.screenID)
                }
            }
        }
    }

    private func audioRow(input: Bool) -> some View {
        let audio = model.audio
        let active = input ? audio.input : audio.output
        let role = input ? "Microphone" : "Output"
        let muted = input ? audio.inputMuted : model.outputMuted
        let level = input ? audio.inputGain : model.volume
        let levelTarget = target(input: input, forMute: false)
        let muteTarget = target(input: input, forMute: true)
        let levelTitle = input ? "Microphone gain" : "Output volume"
        let needsPairing = !input && level == nil && active?.isDisplay == true && model.resolvedDisplayID == nil
            && model.display.displays.contains { $0.volume != nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(role)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                RoutePicker(audio: audio, input: input)
            }
            if active != nil {
                LevelControl(
                    title: levelTitle,
                    symbol: input ? "mic" : "speaker.wave.2",
                    value: level,
                    unavailable: needsPairing ? "Choose a monitor in Settings…" : (input ? "Gain unavailable" : "Volume unavailable"),
                    setValue: { value in
                        guard let levelTarget, levelTarget == target(input: input, forMute: false) else { return }
                        if input { audio.setInputGain(value) } else { model.setVolume(value) }
                    },
                    unavailableAction: needsPairing ? {
                        openSettings()
                        NotificationCenter.default.post(name: .showMonitorPairing, object: nil)
                    } : nil,
                    mute: muted,
                    muteSymbol: input ? "mic.slash.fill" : "speaker.slash.fill",
                    muteTarget: input ? "microphone" : "output",
                    toggleMute: {
                        guard let muted, let muteTarget, muteTarget == target(input: input, forMute: true) else { return }
                        if input { audio.setInputMuted(!muted) } else { model.setOutputMuted(!muted) }
                    }
                )
                .id([levelTarget, muteTarget])
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

/// The menu depends only on device inventory and selection. Level changes do
/// not need to regroup saved device names or rebuild native menu items.
private struct RoutePicker: View {
    let audio: AudioController
    let input: Bool

    var body: some View {
        let active = input ? audio.input : audio.output
        let devices = input ? audio.inputs : audio.outputs
        let available = devices.filter { $0.isConnected && (!$0.isHidden || $0.id == active?.id) }
        if available.isEmpty {
            Text("No device")
                .foregroundStyle(.secondary)
        } else {
            let names = routeLabels(for: devices)
            Picker(input ? "Microphone" : "Output", selection: Binding(
                get: { active?.id },
                set: { id in
                    let live = input ? audio.inputs : audio.outputs
                    guard let shown = available.first(where: { $0.id == id }),
                          let device = live.first(where: { $0.id == shown.id && $0.uid == shown.uid }),
                          device.isConnected, !device.isHidden else { return }
                    audio.select(device)
                }
            )) {
                if active == nil { Text("Choose a device").tag(String?.none) }
                ForEach(available) { device in
                    Text(names[device.id] ?? device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 215, alignment: .trailing)
            .help("Choose " + (input ? "microphone" : "audio output"))
        }
    }
}

private struct LevelControl: View {
    let title: String
    let symbol: String
    let value: Double?
    let unavailable: String
    let setValue: @MainActor (Double) -> Void
    var unavailableAction: (() -> Void)? = nil
    var mute: Bool? = nil
    var muteSymbol = ""
    var muteTarget = ""
    var toggleMute: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let mute {
                let action = (mute ? "Unmute " : "Mute ") + muteTarget
                Button(action: toggleMute) {
                    Image(systemName: mute ? muteSymbol : symbol)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(mute ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .controlSize(.small)
                .frame(width: 36)
                .accessibilityLabel(action)
                .accessibilityValue(mute ? "Muted" : "Unmuted")
                .help(action)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                    .accessibilityHidden(true)
            }
            if let value {
                Slider(value: Binding(get: { value }, set: { setValue($0) }), in: 0...1) {
                    Text(title)
                }
                .labelsHidden()
                .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            } else if let unavailableAction {
                Button(unavailable, action: unavailableAction)
                    .buttonStyle(.link)
                    .font(.callout)
                Spacer()
            } else {
                Text(unavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minHeight: 22)
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
