import AppKit
import AudioRouting
import DisplayHardware
import SwiftUI

extension Notification.Name {
    static let showMonitorPairing = Notification.Name("DeskControls.ShowMonitorPairing")
}

@MainActor
struct SettingsView: View {
    let model: DeskModel
    @State private var tab = SettingsTab.general
    @State private var deviceRole = RouteRole.output
    @State private var confirmImport = false
    @State private var importResult: String?
    @State private var openPairing = false
    @FocusState private var pairingFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(.vertical, 12)

            Divider()

            switch tab {
            case .general: general
            case .devices: devices
            }
        }
        .frame(minWidth: 475, idealWidth: 500, minHeight: 370, idealHeight: 425)
        .onReceive(NotificationCenter.default.publisher(for: .showMonitorPairing)) { _ in
            tab = .general
            openPairing = true
        }
        .alert("Import audio device preferences?", isPresented: $confirmImport) {
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                importResult = model.audio.importLegacyPreferences()
                    ? "Imported audio device preferences."
                    : (model.audio.lastError ?? "There were no preferences to import.")
            }
        } message: {
            Text("Use the order and visibility saved in Audio Priority Bar. Any additional devices stay in the list.")
        }
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.loginEnabled },
                    set: { model.setLoginEnabled($0) }
                ))
                if let message = model.loginMessage {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.loginApprovalPending {
                    HStack {
                        Text("Approval is required in Login Items.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Login Items…", action: model.openLoginSettings)
                    }
                }
            }
            Section {
                Toggle("Use Apple brightness and volume keys", isOn: Binding(
                    get: { model.keysEnabled },
                    set: { model.setKeysEnabled($0) }
                ))
                if model.keysEnabled && !model.keysAuthorized {
                    HStack {
                        Text("Accessibility access is required for keyboard control.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Grant Access…", action: model.requestKeyAccess)
                    }
                }
                if let message = model.keyboardMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Brightness adjusts the screen under the pointer. Volume and mute follow the active audio output.")
            }
            if let output = model.audio.output, output.isDisplay,
               model.audio.outputVolume == nil || model.audio.outputMuted == nil {
                let names = displayLabels(for: model.display.displays)
                let monitors = model.display.displays.filter { $0.volume != nil || $0.muted != nil }
                Section {
                    Picker("Monitor for speakers", selection: Binding(
                        get: { model.volumeDisplayID },
                        set: { id in
                            guard model.audio.output?.uid == output.uid else { return }
                            if let id {
                                guard let shown = monitors.first(where: { $0.id == id }),
                                      model.display.displays.contains(where: {
                                          $0.id == id && $0.screenID == shown.screenID && ($0.volume != nil || $0.muted != nil)
                                      }) else { return }
                            }
                            model.setVolumeDisplay(id)
                        }
                    )) {
                        Text("Automatic").tag(String?.none)
                        ForEach(monitors) { display in
                            Text(names[display.id] ?? display.name).tag(Optional(display.id))
                        }
                        if let id = model.volumeDisplayID, !monitors.contains(where: { $0.id == id }) {
                            Text("Saved monitor (unavailable)").tag(Optional(id)).disabled(true)
                        }
                    }
                    .id(output.uid)
                    .disabled(monitors.isEmpty && model.volumeDisplayID == nil)
                    .focused($pairingFocused)
                } header: {
                    Text("Monitor speakers")
                } footer: {
                    if monitors.isEmpty {
                        Text(model.display.isRefreshing ? "Looking for monitor speaker controls…" : "No connected monitor reports speaker controls.")
                    } else if let monitor = monitors.first(where: { $0.id == model.resolvedDisplayID }) {
                        Text("Speaker controls use \(names[monitor.id] ?? monitor.name).")
                    } else {
                        Text("Choose the physical monitor that plays audio from \(output.name).")
                    }
                }
            }
            if let message = model.statusMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: openPairing) {
            guard openPairing else { return }
            pairingFocused = true
            openPairing = false
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Device priority")
                    .font(.headline)
                Spacer()
                Picker("Device type", selection: $deviceRole) {
                    Text("Outputs").tag(RouteRole.output)
                    Text("Microphones").tag(RouteRole.input)
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Text("The highest available device is preferred. Hide a device to skip it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 10)
            let routes = deviceRole == .input ? model.audio.inputs : model.audio.outputs
            let names = routeLabels(for: routes)
            if routes.isEmpty {
                ContentUnavailableView("No saved devices", systemImage: deviceRole == .input ? "mic" : "speaker.wave.2",
                                       description: Text("Connect a device to add it to this list."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                            if index != 0 { Divider() }
                            deviceRow(route, name: names[route.id] ?? route.name, index: index, count: routes.count)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            if model.audio.canImportLegacyPreferences || importResult != nil {
                Divider()
                HStack {
                    if model.audio.canImportLegacyPreferences {
                        Button("Import from Audio Priority Bar…") { confirmImport = true }
                    }
                    if let result = importResult {
                        Text(result)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    private func deviceRow(_ route: RouteDevice, name: String, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
                .accessibilityLabel("Priority \(index + 1)")
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                if route.isHidden || !route.isConnected {
                    Text(route.isHidden ? (route.isConnected ? "Hidden" : "Hidden · Disconnected") : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            deviceButton("Move \(name) up", icon: "chevron.up") {
                model.audio.move(route, by: -1)
            }
            .disabled(index == 0)
            deviceButton("Move \(name) down", icon: "chevron.down") {
                model.audio.move(route, by: 1)
            }
            .disabled(index == count - 1)
            deviceButton((route.isHidden ? "Show " : "Hide ") + name, icon: route.isHidden ? "eye.slash" : "eye") {
                model.audio.setHidden(!route.isHidden, for: route)
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 39)
    }

    private func deviceButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 20, height: 20)
        }
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case devices = "Devices"
    var id: Self { self }
}
