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
    private let defaults: UserDefaults
    @ObservationIgnored private let media = MediaKeys()
    @ObservationIgnored private var placements: [DisplayPlacement]?
    private var savedPairs: [String: String]
    private var sessionPairs: [String: String] = [:]
    private(set) var keysEnabled: Bool
    private(set) var keysAuthorized = false
    private(set) var keyboardMessage: String?
    private(set) var loginEnabled = false
    private var serviceMessage: String?
    private var loginApprovalPending = false
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
        audio.onOutputChanged = { [weak self] in self?.display.cancelPendingAudioWrites() }
        display.onTopologyChanged = { [weak self] in
            self?.sessionPairs.removeAll()
            self?.placements = nil
        }
        media.target = { [weak self] in self?.target(for: $0) ?? .system }
        media.adjust = { [weak self] in self?.adjust($0, id: $1, fine: $2) }
        display.start()
        audio.start()
        refreshServices()
    }

    func stop() {
        running = false
        media.stop()
        audio.stop()
        display.stop()
    }

    func openedPanel() {
        audio.refreshLevels()
        display.refreshValues()
        refreshServices()
    }

    var statusMessage: String? {
        audio.lastError ?? display.lastError ?? serviceMessage ?? (loginApprovalPending
            ? "Allow Desk Controls in System Settings → General → Login Items." : nil)
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
        return display.displays.first { $0.id == resolved }
    }

    var resolvedDisplayName: String? { resolvedDisplay?.name }
    var volume: Double? { audio.outputVolume ?? resolvedDisplay?.volume }
    var outputMuted: Bool? { audio.outputMuted ?? resolvedDisplay?.muted }

    /// Routing notifications can arrive before the asynchronous device inventory.
    /// Recheck the live system output before accepting a monitor speaker command.
    private var currentSpeakerDisplay: MonitorDisplay? {
        guard let output = audio.output, output.isDisplay, audio.isCurrentOutput(output) else { return nil }
        return resolvedDisplay
    }

    func setVolumeDisplay(_ id: String?) {
        guard let output = audio.output, output.isDisplay else { return }
        if let id, !display.displays.contains(where: { $0.id == id }) { return }
        display.cancelPendingAudioWrites()
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
        else if let screen = currentSpeakerDisplay, screen.volume != nil { display.setVolume(value, for: screen.id) }
    }

    func setOutputMuted(_ muted: Bool) {
        if audio.outputMuted != nil { audio.setOutputMuted(muted) }
        else if let screen = currentSpeakerDisplay, screen.muted != nil { display.setMuted(muted, for: screen.id) }
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
        case .mute:
            guard audio.outputMuted == nil, let screen = currentSpeakerDisplay, screen.muted != nil else { return .system }
            return .monitor(screen.id)
        case .volumeUp, .volumeDown:
            guard audio.outputVolume == nil, let screen = currentSpeakerDisplay, screen.volume != nil else { return .system }
            return .monitor(screen.id)
        }
    }

    private func adjust(_ key: DeskKey, id: String, fine: Bool) {
        guard let screen = display.displays.first(where: { $0.id == id }) else { return }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .brightnessUp, .brightnessDown:
            guard let current = screen.brightness else { return }
            display.setBrightness(min(1, max(0, current + (key == .brightnessUp ? step : -step))), for: id)
        case .volumeUp, .volumeDown:
            guard let current = screen.volume else { return }
            display.setVolume(min(1, max(0, current + (key == .volumeUp ? step : -step))), for: id)
        case .mute:
            if let muted = screen.muted { display.setMuted(!muted, for: id) }
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

    func refreshServices() {
        keysAuthorized = AXIsProcessTrusted()
        if running && keysEnabled && keysAuthorized {
            keyboardMessage = media.start() ? nil : "Keyboard access could not start. Reopen Desk Controls after granting Accessibility access."
        } else {
            media.stop()
            keyboardMessage = nil
        }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginApprovalPending = status == .requiresApproval
    }

    func setLoginEnabled(_ enabled: Bool) {
        serviceMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            serviceMessage = "Open at Login: " + error.localizedDescription
        }
        refreshServices()
    }
}
