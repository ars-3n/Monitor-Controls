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
        // The window's toolbar holds the two tabs. See SettingsTabs.
        Group {
            switch navigation.section {
            case .general:
                GeneralSettings(model: model, navigation: navigation)
            case .devices:
                DevicePriorities(model: model, importResult: importResult,
                                 requestImport: { confirmImport = true })
            }
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
}

private struct GeneralSettings: View {
    let model: DeskModel
    let navigation: SettingsNavigation
    @FocusState private var pairingFocused: Bool

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section {
                    let waiting = model.keysEnabled && !model.keysAuthorized
                    if waiting {
                        LabeledContent {
                            Button(action: model.requestKeyAccess) { Text("Allow Access…").font(DeskType.control) }
                                .controlSize(.regular)
                        } label: {
                            SettingLabel(symbol: "exclamationmark.triangle.fill", color: .yellow,
                                         title: "Keyboard access needed",
                                         detail: "Allow Monitor Controls in Accessibility settings to use these keys.")
                        }
                    }
                    Toggle(isOn: Binding(get: { model.keysEnabled }, set: { model.setKeysEnabled($0) })) {
                        SettingLabel(symbol: "keyboard", color: .orange,
                                     title: "Brightness and volume keys",
                                     detail: "Brightness keys change the display under the pointer.",
                                     dimmed: waiting)
                    }
                    .controlSize(.regular)
                    if let message = model.keyboardMessage {
                        feedback(message)
                    }
                    if let output = model.audio.output, output.isDisplay,
                       model.audio.outputVolume == nil || model.audio.outputMuted == nil {
                        MonitorPairing(model: model, output: output, pairingFocused: $pairingFocused)
                    }
                } header: {
                    Text("Keyboard").font(DeskType.device)
                }

                if let message = model.statusMessage {
                    Section { feedback(message) }
                }

                Section {
                    Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) })) {
                        SettingLabel(symbol: "power", color: .green, title: "Open at login")
                    }
                    .controlSize(.regular)
                    if model.loginApprovalPending {
                        settingsAction("Allow Monitor Controls to open at login in System Settings.",
                                       button: "Open Login Items…", action: model.openLoginSettings)
                    }
                    if let message = model.loginMessage {
                        feedback(message)
                    }
                    updateRows
                } header: {
                    Text("App").font(DeskType.device)
                } footer: {
                    // The last thing on the page. It scrolls with it.
                    Link("Monitor Controls on GitHub", destination: model.updates.repository)
                        .help(model.updates.repository.absoluteString)
                        .font(DeskType.body)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
            }
            .formStyle(.grouped)
            // The window is wide for the two device lists. These rows read
            // better when the label and its control stay close.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
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
                LabeledContent {
                    HStack(spacing: 12) {
                        // Always laid out, so the row keeps its shape while work is under way.
                        ProgressView()
                            .controlSize(.small)
                            .opacity(updates.isBusy ? 1 : 0)
                            .accessibilityHidden(!updates.isBusy)
                        Button(action: row.action) { Text(row.button).font(DeskType.control) }
                            .controlSize(.regular)
                            .disabled(updates.isBusy)
                    }
                } label: {
                    SettingLabel(symbol: "arrow.triangle.2.circlepath", color: .gray, title: row.text,
                                 detail: "Checks GitHub only when you press the button.")
                }
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

    /// A line of text with one button.
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
                SettingLabel(symbol: "speaker.wave.2.fill", color: .blue, title: "Monitor speakers",
                             detail: detail(monitors: monitors, names: names))
            }
            .font(DeskType.body)
            .controlSize(.regular)
            .id(output.uid)
            .disabled(monitors.isEmpty && paired == nil)
            .focused($pairingFocused)
            .id("monitor-pairing")
    }

    /// Says which monitor the volume and mute controls reach right now.
    private func detail(monitors: [MonitorDisplay], names: [String: String]) -> String {
        if monitors.isEmpty {
            return model.display.isRefreshing ? "Looking for speaker controls…"
                : "No connected monitor provides the speaker controls this output needs."
        }
        guard let monitor = monitors.first(where: { $0.id == model.resolvedDisplayID }) else {
            return "Choose the display that plays audio from \(output.name)."
        }
        let name = names[monitor.id] ?? monitor.name
        return model.audio.outputVolume == nil && monitor.volume != nil
            ? "Volume keys and the slider change \(name)." : "Mute changes \(name)."
    }

    private func canControlSpeakers(_ display: MonitorDisplay) -> Bool {
        (model.audio.outputVolume == nil && display.volume != nil) ||
        (model.audio.outputMuted == nil && display.muted != nil)
    }
}

/// A coloured symbol, a title and one line that says what the setting does.
private struct SettingLabel: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    /// Greyed out while the setting cannot take effect.
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(dimmed ? Color.gray : color))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .contentTransition(.opacity)
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .font(DeskType.body)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
