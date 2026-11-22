import AppKit
import ApplicationServices
import AudioRouting
import DeskPolicy
import DisplayHardware
import Observation
import ServiceManagement

@MainActor @Observable
final class DeskModel {
    let audio: AudioController
    let display: DisplayController
    let updates = UpdateModel()
    private let defaults: UserDefaults
    @ObservationIgnored private let media = MediaKeys()
    @ObservationIgnored private let overlay = LevelOverlay()
    @ObservationIgnored private var placements: [DisplayPlacement]?
    private var savedPairs: [String: String]
    private var sessionPairs: [String: String] = [:]
    private(set) var keysEnabled: Bool
    private(set) var keysAuthorized = false
    private(set) var keyboardMessage: String?
    private(set) var loginEnabled = false
    private(set) var loginMessage: String?
    private(set) var loginApprovalPending = false
    private var running = false

    init(audio: AudioController = AudioController(), display: DisplayController = DisplayController(),
         defaults: UserDefaults = .standard) {
        self.audio = audio
        self.display = display
        self.defaults = defaults
        savedPairs = defaults.dictionary(forKey: "displayVolumePairs") as? [String: String] ?? [:]
        keysEnabled = defaults.object(forKey: "mediaKeys") as? Bool ?? true
    }

    func start() {
        guard !running else { return }
        running = true
        audio.onOutputChanged = { [weak self] in self?.invalidateSpeakerControls() }
        display.onTopologyChanged = { [weak self] in
            self?.sessionPairs.removeAll()
            self?.screenParametersChanged()
            self?.media.cancelAdjustments()
        }
        media.target = { [weak self] in self?.target(for: $0) ?? .system }
        media.adjust = { [weak self] in self?.adjust($0, id: $1, fine: $2) }
        display.start()
        audio.start()
        refreshKeyboardService()
    }

    func stop() {
        running = false
        media.stop()
        audio.onOutputChanged = nil
        display.onTopologyChanged = nil
        audio.stop()
        display.stop()
    }

    func screenParametersChanged() { placements = nil }

    func screenDidWake() {
        guard running else { return }
        screenParametersChanged()
        audio.refresh()
        refreshKeyboardService()
    }

    func openedPanel() {
        // Show current levels at once. The device read below repeats this
        // when it finishes, which can be a moment later.
        audio.refreshLevels()
        audio.refresh()
        display.refreshValues(userIsPresent: true)
        refreshKeyboardService()
    }

    /// An error has been seen once the panel that showed it closes.
    func closedPanel() {
        audio.dismissError()
        display.dismissError()
    }

    var statusMessage: String? {
        audio.lastError ?? display.lastError
    }

    var volumeDisplayID: String? {
        guard let output = audio.output, output.isDisplay else { return nil }
        return sessionPairs[output.id] ?? savedPairs[output.id]
    }

    private var resolvedDisplay: MonitorDisplay? {
        guard let output = audio.output, output.isDisplay else { return nil }
        let names = audio.outputs.filter { $0.isDisplay && $0.isConnected }.map(\.name)
        let candidates = display.displays.map { DisplayCandidate(id: $0.id, name: $0.name) }
        let resolved = OutputPairing.resolve(outputName: output.name, connectedDisplayOutputNames: names,
                                             monitors: candidates, preferredID: volumeDisplayID)
        // Match against every connected screen so duplicate names stay ambiguous.
        // A screen that only supports brightness cannot be a speaker-control target.
        return display.displays.first { $0.id == resolved && ($0.volume != nil || $0.muted != nil) }
    }

    var resolvedDisplayID: String? { resolvedDisplay?.id }
    var volume: Double? { audio.outputVolume ?? resolvedDisplay?.volume }
    var outputMuted: Bool? { audio.outputMuted ?? resolvedDisplay?.muted }

    /// The first monitor with a brightness control stands for brightness, as it does in the panel.
    var menuBarLevels: MenuBarLevels {
        MenuBarLevels(brightness: display.displays.lazy.compactMap(\.brightness).first,
                      volume: volume, muted: outputMuted ?? false)
    }

    private func invalidateSpeakerControls() {
        media.cancelAdjustments(audioOnly: true)
        display.cancelPendingAudioWrites()
    }

    func forget(_ device: RouteDevice) {
        guard audio.forget(device), device.role == .output else { return }
        sessionPairs[device.id] = nil
        if savedPairs.removeValue(forKey: device.id) != nil {
            defaults.set(savedPairs, forKey: "displayVolumePairs")
        }
    }

    func setVolumeDisplay(_ id: String?) {
        guard let output = audio.output, output.isDisplay else { return }
        if let id, !display.displays.contains(where: { $0.id == id }) { return }
        invalidateSpeakerControls()
        savedPairs[output.id] = nil
        sessionPairs[output.id] = nil
        if let id, let screen = display.displays.first(where: { $0.id == id }) {
            if screen.canRememberPairing {
                savedPairs[output.id] = id
            } else {
                sessionPairs[output.id] = id
            }
        }
        defaults.set(savedPairs, forKey: "displayVolumePairs")
    }

    func setVolume(_ value: Double) {
        if audio.outputVolume != nil { audio.setOutputVolume(value) }
        else if let screen = resolvedDisplay { setSpeakerVolume(value, on: screen) }
    }

    func setOutputMuted(_ muted: Bool) {
        if audio.outputMuted != nil { audio.setOutputMuted(muted) }
        else if let screen = resolvedDisplay { setSpeakerMuted(muted, on: screen) }
    }

    // The guard checks for changes that arrive before the HAL listener or
    // between the two transfers in a DDC write.
    private func setSpeakerVolume(_ value: Double, on screen: MonitorDisplay) {
        guard screen.volume != nil, let output = audio.output, let routeIsCurrent = audio.outputGuard(for: output) else { return }
        display.setVolume(value, for: screen.id, while: routeIsCurrent)
    }

    private func setSpeakerMuted(_ muted: Bool, on screen: MonitorDisplay) {
        guard screen.muted != nil, let output = audio.output, let routeIsCurrent = audio.outputGuard(for: output) else { return }
        display.setMuted(muted, for: screen.id, while: routeIsCurrent)
    }

    private func target(for key: DeskKey) -> KeyTarget {
        switch key {
        case .brightnessDown, .brightnessUp:
            if placements == nil {
                placements = NSScreen.screens.compactMap { screen -> DisplayPlacement? in
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                    return DisplayPlacement(screenID: id.uint32Value, frame: screen.frame)
                }
            }
            guard let id = DisplayPlacement.atPointer(NSEvent.mouseLocation, screens: placements ?? []) else { return .system }
            let monitor = display.displays.first { $0.screenID == id && $0.brightness != nil }
            return .brightness(external: CGDisplayIsBuiltin(id) == 0, controllableID: monitor?.id)
        case .mute, .volumeUp, .volumeDown:
            let isMute = key == .mute
            guard (isMute ? audio.outputMuted == nil : audio.outputVolume == nil),
                  let output = audio.output, output.isDisplay,
                  // HAL can announce the new output before its inventory has refreshed.
                  // Let macOS handle the key once it has retired the cached monitor route.
                  audio.outputGuard(for: output) != nil,
                  let screen = resolvedDisplay,
                  (isMute ? screen.muted != nil : screen.volume != nil) else { return .system }
            return .monitor(screen.id)
        }
    }

    /// The brightness indicator appears under this view, the menu-bar icon.
    func anchorIndicator(to view: NSView) { overlay.anchor = view }

    private func adjust(_ key: DeskKey, id: String, fine: Bool) {
        // The step starts from the monitor's level, which its own buttons or
        // another computer may have changed since the last read.
        display.withCurrentLevels { [weak self] in self?.step(key, id: id, fine: fine) }
    }

    private func step(_ key: DeskKey, id: String, fine: Bool) {
        guard let screen = display.displays.first(where: { $0.id == id }) else { return }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .brightnessUp, .brightnessDown:
            guard let current = screen.brightness else { return }
            let value = min(1, max(0, current + (key == .brightnessUp ? step : -step)))
            display.setBrightness(value, for: id)
            overlay.show(brightness: value, onScreen: screen.screenID)
        case .volumeUp, .volumeDown:
            guard let current = screen.volume else { return }
            // No overlay here: monitors show their own for volume and mute.
            setSpeakerVolume(min(1, max(0, current + (key == .volumeUp ? step : -step))), on: screen)
        case .mute:
            if let muted = screen.muted { setSpeakerMuted(!muted, on: screen) }
        }
    }

    func setKeysEnabled(_ enabled: Bool) {
        keysEnabled = enabled
        defaults.set(enabled, forKey: "mediaKeys")
        refreshServices()
    }

    func requestKeyAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshServices()
    }

    private func refreshKeyboardService() {
        keysAuthorized = AXIsProcessTrusted()
        if running && keysEnabled && keysAuthorized {
            keyboardMessage = media.start() ? nil : "Keyboard access could not start. Reopen Monitor Controls after granting Accessibility access."
        } else {
            media.stop()
            keyboardMessage = nil
        }
    }

    func refreshServices(checkLogin: Bool = true) {
        refreshKeyboardService()
        guard checkLogin else { return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginApprovalPending = status == .requiresApproval
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginMessage = nil
        do {
            let service = SMAppService.mainApp
            let status = service.status
            let registered = status == .enabled || status == .requiresApproval
            if enabled && !registered { try service.register() }
            if !enabled && registered { try service.unregister() }
        } catch {
            loginMessage = error.localizedDescription
        }
        refreshServices()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
