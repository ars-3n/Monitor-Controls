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
                Label("Devices", systemImage: "headphones")
                    .tag(SettingsSection.devices)
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 230)
            .toolbar(removing: .sidebarToggle)
            .accessibilityLabel("Settings sections")
        } detail: {
            Group {
                switch navigation.section {
                case .general:
                    GeneralSettings(model: model, navigation: navigation)
                case .devices:
                    DevicePriorities(model: model, importResult: importResult,
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
        case .devices: "Devices"
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

                if let message = model.statusMessage {
                    Section { feedback(message) }
                }

                Section {
                    updateRows
                } header: {
                    Text("Updates").font(DeskType.device)
                } footer: {
                    // The version line is the last thing on the page and
                    // scrolls with it.
                    VStack(spacing: 28) {
                        Text("Monitor Controls looks for a new version on GitHub only when you press the button.")
                            .font(DeskType.body)
                            .foregroundStyle(.secondary)
                            .settingsFooter()
                        about
                    }
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

    private var about: some View {
        let updates = model.updates
        return HStack(spacing: 6) {
            Group {
                Text("Monitor Controls \(updates.version)")
                Text("·").accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            Link("GitHub", destination: updates.repository)
                .help(updates.repository.absoluteString)
        }
        .font(DeskType.body)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var updateRows: some View {
        let updates = model.updates
        Group {
            if case .failed(let message, let release) = updates.state {
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
            } else {
                // One row for every other state, so only its text changes.
                let row = updateRow(updates)
                settingsAction(row.text, busy: updates.isBusy, button: row.button, action: row.action)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updates.state)
    }

    private func updateRow(_ updates: UpdateModel) -> (text: String, button: String, action: () -> Void) {
        switch updates.state {
        case .idle, .failed:
            return ("Version \(updates.version)", "Check for Updates", updates.check)
        case .checking:
            return ("Checking for updates…", "Check for Updates", {})
        case .current:
            return ("Version \(updates.version) is the latest.", "Check for Updates", updates.check)
        case .available(let release):
            if let blocker = updates.installBlocker {
                return ("Version \(release.version) is available. \(blocker)", "Open Release Page",
                        { updates.openPage(of: release) })
            }
            return ("Version \(release.version) is available. You have \(updates.version).", "Install and Relaunch",
                    { updates.install(release) })
        case .installing(let release):
            return ("Installing version \(release.version)…", "Install and Relaunch", {})
        }
    }

    /// A line of text with one button. `busy` reserves room for a spinner
    /// beside the button, so the row keeps its shape while work is under way.
    private func settingsAction(_ explanation: String, busy: Bool? = nil, button: String,
                                action: @escaping () -> Void) -> some View {
        let actionButton = Button(action: action) { Text(button).font(DeskType.control) }
            .controlSize(.regular)
            .disabled(busy == true)
        let spinner = ProgressView()
            .controlSize(.small)
            .opacity(busy == true ? 1 : 0)
            .accessibilityHidden(busy != true)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(explanation).fixedSize().contentTransition(.opacity)
                Spacer(minLength: 0)
                if busy != nil { spinner }
                actionButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(explanation).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    actionButton
                    if busy != nil { spinner }
                }
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

/// Outputs and microphones side by side. The two lists share one scroll
/// view, so the page moves as a whole.
private struct DevicePriorities: View {
    let model: DeskModel
    let importResult: String?
    let requestImport: () -> Void

    /// A grouped form insets its cards by this much on each side.
    private static let edge: CGFloat = 20
    /// How far each column moves toward the other, so the gap between the
    /// cards is narrower than two form insets.
    private static let overlap: CGFloat = 12

    var body: some View {
        let audio = model.audio
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Above the lists, so it is read before the numbers and
                // stays in view however long the lists are.
                Text("Automatic switching prefers devices higher in each list. Hidden devices are skipped. A device you pick yourself stays in use until it disconnects or a higher one connects.")
                    .font(DeskType.body)
                    .foregroundStyle(.secondary)
                    .settingsFooter()
                    .padding(.horizontal, Self.edge + 10)
                    .padding(.top, 14)
                HStack(alignment: .top, spacing: 0) {
                    DeviceColumn(model: model, role: .output)
                        .padding(.trailing, -Self.overlap)
                    DeviceColumn(model: model, role: .input)
                        .padding(.leading, -Self.overlap)
                }
                VStack(alignment: .leading, spacing: 12) {
                    if audio.canImportLegacyPreferences {
                        Button(action: requestImport) {
                            Text("Import from Audio Priority Bar…").font(DeskType.control)
                        }
                        .controlSize(.regular)
                    }
                    if let importResult {
                        Text(importResult)
                            .foregroundStyle(.secondary)
                            .settingsFooter()
                    }
                }
                .font(DeskType.body)
                // Lines up with the text inside the cards above.
                .padding(.horizontal, Self.edge + 10)
                .padding(.bottom, 20)
            }
            // The General page's cards start this much further in.
            .padding(.horizontal, 6)
        }
    }
}

/// One role's devices: the numbered list, then the hidden ones.
private struct DeviceColumn: View {
    let model: DeskModel
    let role: RouteRole

    var body: some View {
        let audio = model.audio
        let routes = role == .input ? audio.inputs : audio.outputs
        let currentID = role == .input ? audio.input?.id : audio.output?.id
        let names = routeLabels(for: routes)
        let shown = routes.filter { !$0.isHidden }
        let hidden = routes.filter(\.isHidden)
        let title = role == .input ? "Microphones" : "Outputs"

        Form {
            Section {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, route in
                    DeviceRow(model: model, route: route, name: names[route.id] ?? route.name,
                              position: index + 1, count: shown.count, active: route.id == currentID)
                }
                if shown.isEmpty {
                    Text(routes.isEmpty ? "Connect a device to add it to this list." : "Every device is hidden.")
                        .font(DeskType.body)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 6) {
                    // One box for both symbols keeps the two titles on a line.
                    Image(systemName: role == .input ? "mic" : "speaker.wave.2")
                        .frame(width: 22, height: 18)
                        .accessibilityHidden(true)
                    Text(title)
                }
                .font(DeskType.device)
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
                    // Quieter than the column title it sits under.
                    Text("Hidden")
                        .font(DeskType.control)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hidden \(title.lowercased())")
                }
            }
        }
        .formStyle(.grouped)
        // The page scrolls both columns together.
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
                    Text(status).lineLimit(1)
                }
                .font(DeskType.body)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)

            HStack(spacing: 0) {
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
                .frame(width: 26, height: 28)
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
