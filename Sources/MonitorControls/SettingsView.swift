import AudioRouting
import DisplayHardware
import SwiftUI

@MainActor
struct SettingsView: View {
    let model: DeskModel
    let navigation: SettingsNavigation

    @State private var confirmImport = false
    @State private var importResult: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .zIndex(1)
            VStack(alignment: .leading, spacing: 0) {
                Text(sectionTitle)
                    .font(DeskType.title)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                switch navigation.section {
                case .general:
                    GeneralSettings(model: model, navigation: navigation)
                case .outputs, .microphones:
                    DevicePriorities(audio: model.audio,
                                     role: navigation.section == .outputs ? .output : .input,
                                     importResult: importResult,
                                     requestImport: { confirmImport = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $confirmImport) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import audio device preferences?")
                    .font(DeskType.heading)
                    .accessibilityAddTraits(.isHeader)
                Text("Use the order and visibility saved in Audio Priority Bar. Any additional devices stay in the list.")
                    .font(DeskType.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { confirmImport = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") {
                        importResult = model.audio.importLegacyPreferences()
                            ? "Imported device order and visibility."
                            : (model.audio.lastError ?? "There were no preferences to import.")
                        confirmImport = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .font(DeskType.control)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 420)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(DeskType.heading)
                .padding(.leading, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            List(selection: Binding<SettingsSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                Label("General", systemImage: "gearshape")
                    .font(DeskType.control)
                    .tag(SettingsSection.general)
                Section {
                    Label("Outputs", systemImage: "speaker.wave.2")
                        .font(DeskType.control)
                        .tag(SettingsSection.outputs)
                    Label("Microphones", systemImage: "mic")
                        .font(DeskType.control)
                        .tag(SettingsSection.microphones)
                } header: {
                    Text("Device priority")
                        .font(DeskType.body.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .collapsible(false)
            }
            .environment(\.defaultMinListRowHeight, 30)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Settings sections")
        }
        .frame(width: 162)
        .modifier(SidebarSurface())
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private var sectionTitle: String {
        switch navigation.section {
        case .general: "General"
        case .outputs: "Outputs"
        case .microphones: "Microphones"
        }
    }
}

private struct SidebarSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct GeneralSettings: View {
    let model: DeskModel
    let navigation: SettingsNavigation
    @FocusState private var pairingFocused: Bool

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) })) {
                        Text("Open at login").font(DeskType.body)
                    }
                    .controlSize(.regular)
                    if model.loginApprovalPending {
                        settingsAction("Allow Monitor Controls to open at login in System Settings.",
                                       button: "Open Login Items…", action: model.openLoginSettings)
                    }
                    if let message = model.loginMessage {
                        feedback(message)
                    }
                } header: {
                    Text("Startup").font(DeskType.device)
                }

                Section {
                    Toggle(isOn: Binding(get: { model.keysEnabled }, set: { model.setKeysEnabled($0) })) {
                        Text("Use brightness and volume keys").font(DeskType.body)
                    }
                    .controlSize(.regular)
                    if model.keysEnabled && !model.keysAuthorized {
                        settingsAction("Allow keyboard control in Accessibility settings.",
                                       button: "Grant Access…", action: model.requestKeyAccess)
                    }
                    if let message = model.keyboardMessage {
                        feedback(message)
                    }
                } header: {
                    Text("Keyboard").font(DeskType.device)
                } footer: {
                    Text("Brightness keys adjust the display under the pointer. Volume and mute follow the active output.")
                        .font(DeskType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let output = model.audio.output, output.isDisplay,
                   model.audio.outputVolume == nil || model.audio.outputMuted == nil {
                    MonitorPairing(model: model, output: output, pairingFocused: $pairingFocused)
                }

                if let message = model.statusMessage {
                    Section { feedback(message) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .task(id: navigation.pairingRequest) {
                guard navigation.pairingRequest > 0 else { return }
                scroll.scrollTo("monitor-pairing", anchor: .center)
                pairingFocused = true
                navigation.pairingRequest = 0
            }
        }
    }

    private func settingsAction(_ explanation: String, button: String, action: @escaping () -> Void) -> some View {
        let actionButton = Button(action: action) { Text(button).font(DeskType.control) }
            .controlSize(.regular)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(explanation).fixedSize()
                Spacer(minLength: 0)
                actionButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(explanation).fixedSize(horizontal: false, vertical: true)
                actionButton
            }
        }
        .font(DeskType.body)
    }

    private func feedback(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(DeskType.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct MonitorPairing: View {
    let model: DeskModel
    let output: RouteDevice
    @FocusState.Binding var pairingFocused: Bool

    var body: some View {
        let displays = model.display.displays
        let names = displayLabels(for: displays)
        let monitors = displays.filter(canControlSpeakers)
        let paired = model.volumeDisplayID

        Section {
            Picker(selection: Binding(
                get: { model.volumeDisplayID },
                set: { id in
                    guard model.audio.output?.uid == output.uid else { return }
                    if let id {
                        guard let shown = monitors.first(where: { $0.id == id }),
                              model.display.displays.contains(where: {
                                  $0.id == id && $0.screenID == shown.screenID && canControlSpeakers($0)
                              }) else { return }
                    }
                    model.setVolumeDisplay(id)
                }
            )) {
                Text("Automatic").font(DeskType.body).tag(String?.none)
                ForEach(monitors) { display in
                    Text(names[display.id] ?? display.name).font(DeskType.body).tag(Optional(display.id))
                }
                if let paired, !monitors.contains(where: { $0.id == paired }) {
                    Text("Saved display (unavailable)").font(DeskType.body).tag(Optional(paired)).disabled(true)
                }
            } label: {
                Text("Control speakers on").font(DeskType.body)
            }
            .font(DeskType.body)
            .controlSize(.regular)
            .id(output.uid)
            .disabled(monitors.isEmpty && paired == nil)
            .focused($pairingFocused)
            .id("monitor-pairing")
        } header: {
            Text("Monitor speakers").font(DeskType.device)
        } footer: {
            Group {
                if monitors.isEmpty {
                    Text(model.display.isRefreshing ? "Looking for speaker controls…" : "No connected monitor provides the speaker controls this output needs.")
                } else if let monitor = monitors.first(where: { $0.id == model.resolvedDisplayID }) {
                    let name = names[monitor.id] ?? monitor.name
                    if model.audio.outputVolume == nil && monitor.volume != nil {
                        Text("Volume controls adjust the speakers on \(name).")
                    } else {
                        Text("Mute controls the speakers on \(name).")
                    }
                } else {
                    Text("Choose the display that plays audio from \(output.name).")
                }
            }
            .font(DeskType.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func canControlSpeakers(_ display: MonitorDisplay) -> Bool {
        (model.audio.outputVolume == nil && display.volume != nil) ||
        (model.audio.outputMuted == nil && display.muted != nil)
    }
}

private struct DevicePriorities: View {
    let audio: AudioController
    let role: RouteRole
    let importResult: String?
    let requestImport: () -> Void

    var body: some View {
        let routes = role == .input ? audio.inputs : audio.outputs
        let currentID = role == .input ? audio.input?.id : audio.output?.id
        let names = routeLabels(for: routes)

        VStack(alignment: .leading, spacing: 0) {
            Text("Automatic switching prefers devices higher in this list. Hidden devices are skipped.")
                .font(DeskType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 16)

            if routes.isEmpty {
                ContentUnavailableView {
                    Label(role == .input ? "No saved microphones" : "No saved outputs",
                          systemImage: role == .input ? "mic" : "speaker.wave.2")
                        .font(DeskType.heading)
                } description: {
                    Text("Connect a device to add it to this list.")
                        .font(DeskType.body)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                            DeviceRow(audio: audio, route: route, name: names[route.id] ?? route.name,
                                      position: index + 1, count: routes.count, active: route.id == currentID)
                            if index < routes.count - 1 { Divider().accessibilityHidden(true) }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .id(role)
            }

            if audio.canImportLegacyPreferences || importResult != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if audio.canImportLegacyPreferences {
                        Button(action: requestImport) {
                            Text("Import from Audio Priority Bar…").font(DeskType.control)
                        }
                        .controlSize(.regular)
                    }
                    if let importResult {
                        Text(importResult)
                            .font(DeskType.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DeviceRow: View {
    let audio: AudioController
    let route: RouteDevice
    let name: String
    let position: Int
    let count: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(DeskType.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
                .accessibilityLabel("Priority \(position)")

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(DeskType.device)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(name)
                HStack(spacing: 4) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(status)
                }
                .font(DeskType.body)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)

            HStack(spacing: 2) {
                actionButton("Move \(name) up", symbol: "chevron.up") { audio.move(route, by: -1) }
                    .disabled(position == 1)
                actionButton("Move \(name) down", symbol: "chevron.down") { audio.move(route, by: 1) }
                    .disabled(position == count)
                actionButton((route.isHidden ? "Show " : "Hide ") + name, symbol: route.isHidden ? "eye.slash" : "eye") {
                    audio.setHidden(!route.isHidden, for: route)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var status: String {
        let connection = active ? "In use" : (route.isConnected ? "Connected" : "Disconnected")
        return route.isHidden ? connection + " · Hidden" : connection
    }

    private func actionButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DeskType.control)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }
}
