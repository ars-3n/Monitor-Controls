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
        // The system split view supplies the sidebar, its material and the
        // title bar on every macOS version.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<SettingsSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)
                Section("Device priority") {
                    Label("Outputs", systemImage: "speaker.wave.2")
                        .tag(SettingsSection.outputs)
                    Label("Microphones", systemImage: "mic")
                        .tag(SettingsSection.microphones)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 230)
            .toolbar(removing: .sidebarToggle)
            .accessibilityLabel("Settings sections")
        } detail: {
            Group {
                switch navigation.section {
                case .general:
                    GeneralSettings(model: model, navigation: navigation)
                case .outputs, .microphones:
                    DevicePriorities(model: model,
                                     role: navigation.section == .outputs ? .output : .input,
                                     importResult: importResult,
                                     requestImport: { confirmImport = true })
                }
            }
            .navigationTitle(sectionTitle)
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

    private var sectionTitle: String {
        switch navigation.section {
        case .general: "General"
        case .outputs: "Outputs"
        case .microphones: "Microphones"
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
                        .settingsFooter()
                }

                if let output = model.audio.output, output.isDisplay,
                   model.audio.outputVolume == nil || model.audio.outputMuted == nil {
                    MonitorPairing(model: model, output: output, pairingFocused: $pairingFocused)
                }

                Section {
                    updateRows
                } header: {
                    Text("Updates").font(DeskType.device)
                } footer: {
                    Text("Monitor Controls looks for a new version on GitHub only when you press the button.")
                        .font(DeskType.body)
                        .foregroundStyle(.secondary)
                        .settingsFooter()
                }

                if let message = model.statusMessage {
                    Section { feedback(message) }
                }
            }
            .formStyle(.grouped)
            .task(id: navigation.pairingRequest) {
                guard navigation.pairingRequest > 0 else { return }
                scroll.scrollTo("monitor-pairing", anchor: .center)
                pairingFocused = true
                navigation.pairingRequest = 0
            }
        }
    }

    @ViewBuilder private var updateRows: some View {
        let updates = model.updates
        switch updates.state {
        case .idle:
            settingsAction("Version \(updates.version)", button: "Check for Updates", action: updates.check)
        case .checking:
            progress("Checking for updates…")
        case .current:
            settingsAction("Version \(updates.version) is the latest.", button: "Check Again", action: updates.check)
        case .available(let release):
            if let blocker = updates.installBlocker {
                settingsAction("Version \(release.version) is available. \(blocker)", button: "Open Release Page") {
                    updates.openPage(of: release)
                }
            } else {
                settingsAction("Version \(release.version) is available. You have \(updates.version).",
                               button: "Install and Relaunch") { updates.install(release) }
            }
        case .installing(let release):
            progress("Installing version \(release.version)…")
        case .failed(let message, let release):
            feedback(message)
            HStack(spacing: 8) {
                if let release {
                    Button { updates.install(release) } label: { Text("Try Again").font(DeskType.control) }
                    Button { updates.openPage(of: release) } label: { Text("Open Release Page").font(DeskType.control) }
                } else {
                    Button(action: updates.check) { Text("Check Again").font(DeskType.control) }
                }
            }
            .controlSize(.regular)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(DeskType.body)
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
            .settingsFooter()
        }
    }

    private func canControlSpeakers(_ display: MonitorDisplay) -> Bool {
        (model.audio.outputVolume == nil && display.volume != nil) ||
        (model.audio.outputMuted == nil && display.muted != nil)
    }
}

private struct DevicePriorities: View {
    let model: DeskModel
    private var audio: AudioController { model.audio }
    let role: RouteRole
    let importResult: String?
    let requestImport: () -> Void

    var body: some View {
        let routes = role == .input ? audio.inputs : audio.outputs
        let currentID = role == .input ? audio.input?.id : audio.output?.id
        let names = routeLabels(for: routes)
        let shown = routes.filter { !$0.isHidden }
        let hidden = routes.filter(\.isHidden)

        if routes.isEmpty && !audio.canImportLegacyPreferences && importResult == nil {
            ContentUnavailableView {
                Label(role == .input ? "No saved microphones" : "No saved outputs",
                      systemImage: role == .input ? "mic" : "speaker.wave.2")
            } description: {
                Text("Connect a device to add it to this list.")
            }
        } else {
            Form {
                if !routes.isEmpty {
                    Section {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, route in
                            DeviceRow(model: model, route: route, name: names[route.id] ?? route.name,
                                      position: index + 1, count: shown.count, active: route.id == currentID)
                        }
                        if shown.isEmpty {
                            Text("Every device is hidden.")
                                .font(DeskType.body)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Automatic switching prefers devices higher in this list. Hidden devices are skipped.")
                            .font(DeskType.body)
                            .foregroundStyle(.secondary)
                            .settingsFooter()
                    }
                }
                if !hidden.isEmpty {
                    // Hidden devices take no part in automatic switching,
                    // so they have no priority number or arrows.
                    Section {
                        ForEach(hidden, id: \.id) { route in
                            DeviceRow(model: model, route: route, name: names[route.id] ?? route.name,
                                      position: nil, count: 0, active: route.id == currentID)
                        }
                    } header: {
                        Text("Hidden").font(DeskType.device)
                    }
                }
                if audio.canImportLegacyPreferences || importResult != nil {
                    Section {
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
                }
            }
            .formStyle(.grouped)
            .id(role)
        }
    }
}

private struct DeviceRow: View {
    let model: DeskModel
    private var audio: AudioController { model.audio }
    let route: RouteDevice
    let name: String
    /// Nil for a hidden device.
    let position: Int?
    let count: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            // An empty label keeps the names of both groups in one column.
            Text(position.map { "\($0)" } ?? "")
                .font(DeskType.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
                .accessibilityLabel(position.map { "Priority \($0)" } ?? "")
                .accessibilityHidden(position == nil)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(DeskType.device)
                    .foregroundStyle(position == nil ? .secondary : .primary)
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
                // Forget sits first, so the other buttons keep their columns
                // and the eye stays at the trailing edge on every row.
                if !route.isConnected {
                    actionButton("Forget " + name, symbol: "trash") { model.forget(route) }
                }
                if let position {
                    actionButton("Move \(name) up", symbol: "chevron.up") { audio.move(route, by: -1) }
                        .disabled(position == 1)
                    actionButton("Move \(name) down", symbol: "chevron.down") { audio.move(route, by: 1) }
                        .disabled(position == count)
                }
                actionButton((route.isHidden ? "Show " : "Hide ") + name, symbol: route.isHidden ? "eye.slash" : "eye") {
                    audio.setHidden(!route.isHidden, for: route)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        active ? "In use" : (route.isConnected ? "Connected" : "Disconnected")
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

private extension View {
    /// Section footers read from the leading edge, like the rows above them.
    func settingsFooter() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
