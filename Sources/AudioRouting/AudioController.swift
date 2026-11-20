import CoreAudio
import Foundation
import Observation

struct AudioSnapshot: Sendable {
    let endpoints: [Endpoint]
    let inputID: AudioObjectID?
    let outputID: AudioObjectID?

    init?(endpoints: [Endpoint], inputID: AudioObjectID?, outputID: AudioObjectID?) {
        // HAL publishes topology and default changes independently. A default
        // pointing outside this enumeration means it is not a coherent snapshot.
        for (id, role) in [(inputID, RouteRole.input), (outputID, .output)] {
            if let id, !endpoints.contains(where: { $0.objectID == id && $0.role == role }) { return nil }
        }
        self.endpoints = endpoints
        self.inputID = inputID
        self.outputID = outputID
    }

    var defaultsAreCurrent: Bool {
        CoreAudioProperties.defaultDevice(.input) == inputID && CoreAudioProperties.defaultDevice(.output) == outputID
    }

    static func read() -> Self? {
        guard let endpoints = CoreAudioProperties.inventory() else { return nil }
        return Self(endpoints: endpoints, inputID: CoreAudioProperties.defaultDevice(.input),
                    outputID: CoreAudioProperties.defaultDevice(.output))
    }
}

@MainActor @Observable public final class AudioController {
    public private(set) var inputs: [RouteDevice] = []
    public private(set) var outputs: [RouteDevice] = []
    public private(set) var input: RouteDevice?
    public private(set) var output: RouteDevice?
    public private(set) var inputGain: Double?
    public private(set) var outputVolume: Double?
    public private(set) var inputMuted: Bool?
    public private(set) var outputMuted: Bool?
    public private(set) var lastError: String?
    public private(set) var canImportLegacyPreferences: Bool
    @ObservationIgnored public var onOutputChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inventoryInFlight = false
    @ObservationIgnored private let reader = DispatchQueue(label: "audio.routing.inventory", qos: .userInitiated)
    @ObservationIgnored private let listeners = AudioListeners()
    @ObservationIgnored private var retryListeners: Task<Void, Never>?
    @ObservationIgnored private var retryInventory: Task<Void, Never>?
    @ObservationIgnored private var retriesRemaining = 3
    @ObservationIgnored private var levelRefreshPending = false
    @ObservationIgnored private let activeOutput = OutputIdentity()
    @ObservationIgnored private let gainMute = GainMuteRecovery()
    @ObservationIgnored private var snapshot: AudioSnapshot?
    @ObservationIgnored private var preferences: RoutePreferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var policies: [RouteRole: RoutePolicy] = [:]
    private static let preferenceKey = "audioRoutes.v1"

    public init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferenceKey),
           let saved = try? JSONDecoder().decode(RoutePreferences.self, from: data) {
            preferences = saved
        } else {
            if let unreadable = defaults.data(forKey: Self.preferenceKey) {
                defaults.set(unreadable, forKey: Self.preferenceKey + ".unreadable")
            }
            preferences = RoutePreferences()
        }
        policies[.input] = RoutePolicy(heldID: preferences.inputHold)
        policies[.output] = RoutePolicy(heldID: preferences.outputHold)
        canImportLegacyPreferences = !preferences.importedLegacy && RoutePreferences.containsLegacyChoices(
            defaults.persistentDomain(forName: "app.audioprioritybar") ?? [:])
    }

    public func start() {
        guard !running else { return }
        running = true
        policies[.input] = RoutePolicy(heldID: preferences.inputHold)
        policies[.output] = RoutePolicy(heldID: preferences.outputHold)
        listeners.receive = { [weak self] event in self?.handle(event) }
        attachListeners()
        refresh()
    }

    public func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        retryInventory?.cancel()
        retryInventory = nil
        retryListeners?.cancel()
        retryListeners = nil
        listeners.stop()
        listeners.receive = nil
        activeOutput.invalidate()
        onOutputChanged?()
    }

    private func attachListeners() {
        if listeners.attachSystem() {
            retryListeners?.cancel()
            retryListeners = nil
        } else if retryListeners == nil {
            retryListeners = Task { [weak self] in
                var delay = 1
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self, self.running else { return }
                    if self.listeners.attachSystem() {
                        self.retryListeners = nil
                        self.refresh()
                        return
                    }
                    delay = min(30, delay * 2)
                }
            }
        }
    }

    private func handle(_ event: AudioEvent) {
        guard running else { return }
        switch event {
        case .topology, .defaults:
            noticeOutputChange()
            refresh()
        case .restart:
            // Core Audio can recycle both the object ID and UID when it
            // restarts. Invalidate old display commands even in that case.
            activeOutput.invalidate()
            onOutputChanged?()
            listeners.stop()
            attachListeners()
            noticeOutputChange()
            refresh()
        case .levels:
            guard !levelRefreshPending else { return }
            levelRefreshPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                levelRefreshPending = false
                if running { refreshLevels() }
            }
        }
    }

    private func noticeOutputChange() {
        let id = CoreAudioProperties.defaultDevice(.output)
        let uid = id.flatMap(CoreAudioProperties.deviceUID)
        if activeOutput.update(objectID: id, uid: uid) { onOutputChanged?() }
    }

    public func refresh() {
        guard running else { return }
        retriesRemaining = 3
        requestInventory()
    }

    private func requestInventory() {
        generation &+= 1
        guard !inventoryInFlight else { return }
        inventoryInFlight = true
        let epoch = generation
        reader.async { [weak self] in
            let update = AudioSnapshot.read()
            Task { @MainActor [weak self] in
                guard let self else { return }
                inventoryInFlight = false
                guard running else { return }
                guard generation == epoch else {
                    requestInventory()
                    return
                }
                let incomplete = update?.endpoints.contains { $0.followsPort == nil } ?? true
                if let update { apply(update) }
                if incomplete, retriesRemaining > 0, retryInventory == nil {
                    let delay = 4 - retriesRemaining
                    retriesRemaining -= 1
                    retryInventory = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(250 * delay)) } catch { return }
                        guard let self, running else { return }
                        retryInventory = nil
                        requestInventory()
                    }
                }
            }
        }
    }

    private func apply(_ update: AudioSnapshot) {
        guard running else { return }
        guard update.defaultsAreCurrent else {
            requestInventory()
            return
        }
        let before = preferences
        snapshot = update
        preferences.remember(update.endpoints)
        let newInputs = preferences.devices(update.endpoints, role: .input)
        let newOutputs = preferences.devices(update.endpoints, role: .output)
        if inputs != newInputs { inputs = newInputs }
        if outputs != newOutputs { outputs = newOutputs }
        func current(_ role: RouteRole, _ id: AudioObjectID?, _ devices: [RouteDevice]) -> RouteDevice? {
            guard let id, let physical = update.endpoints.first(where: { $0.role == role && $0.objectID == id }) else { return nil }
            return devices.first { $0.uid == physical.uid && $0.isConnected }
        }
        let newInput = current(.input, update.inputID, inputs)
        let newOutput = current(.output, update.outputID, outputs)
        if input != newInput { input = newInput }
        if output != newOutput { output = newOutput }
        noticeOutputChange()
        let live = [newInput, newOutput].compactMap { $0 }.compactMap(endpoint)
        listeners.watch(live)
        refreshLevels()
        // Both roles are evaluated together: macOS sometimes changes both
        // defaults before either Core Audio notification is delivered.
        for role in RouteRole.allCases {
            // A USB driver can enumerate before its port descriptor. Leave
            // the held route intact during bounded identity retries.
            if retriesRemaining > 0, update.endpoints.contains(where: { $0.role == role && $0.followsPort == nil }) { continue }
            let current = role == .input ? newInput : newOutput
            let devices = role == .input ? inputs : outputs
            let ranked = preferences.rankedIDs(for: role)
            let desired = policies[role, default: RoutePolicy()].desired(current: current, devices: devices, rankedIDs: ranked,
                                                                        time: ProcessInfo.processInfo.systemUptime)
            if let desired, desired.id != current?.id, let current, let old = endpoint(current), CoreAudioProperties.isCurrent(old),
               changeDefault(desired) {
                policies[role]?.didSelect(desired, manually: false, replacing: current)
            }
        }
        persistIfChanged(since: before)
    }

    private func endpoint(_ device: RouteDevice) -> Endpoint? {
        snapshot?.endpoints.first { $0.uid == device.uid && $0.role == device.role }
    }

    /// Creating the guard only examines our snapshot. Invoke it on the
    /// hardware worker immediately before issuing a monitor speaker command.
    public func outputGuard(for device: RouteDevice) -> (@Sendable () -> Bool)? {
        guard running, output == device, device.role == .output, let e = endpoint(device) else { return nil }
        return activeOutput.guardFor(e) { CoreAudioProperties.isCurrent(e) }
    }

    private func changeDefault(_ device: RouteDevice) -> Bool {
        guard running, let e = endpoint(device), device.isConnected, CoreAudioProperties.deviceUID(e.objectID) == e.uid,
              CoreAudioProperties.setDefault(e.objectID, role: e.role) else { return false }
        if e.role == .output { noticeOutputChange() }
        return true
    }

    public func select(_ device: RouteDevice) {
        guard changeDefault(device) else {
            lastError = "This audio device is no longer available."
            refresh()
            return
        }
        let before = preferences
        policies[device.role, default: RoutePolicy()].didSelect(device, manually: true, replacing: device.role == .input ? input : output)
        lastError = nil
        persistIfChanged(since: before)
        refresh()
    }

    public func refreshLevels() {
        func levels(_ device: RouteDevice?) -> (Double?, Bool?) {
            guard let device, let e = endpoint(device), CoreAudioProperties.isCurrent(e) else { return (nil, nil) }
            let volume = CoreAudioProperties.volume(e)
            var muted = CoreAudioProperties.mute(e)
            if let volume, muted == nil || preferences.levelsBeforeMute[device.id] != nil {
                let scalarMuted = gainMute.isMuted(id: device.id, current: volume, saved: preferences.levelsBeforeMute[device.id]) {
                    storeLevelBeforeMute($0, for: device.id)
                }
                muted = (muted == true) || scalarMuted
            }
            return (volume, muted)
        }
        let (gain, micMute) = levels(input)
        let (volume, speakerMute) = levels(output)
        if inputGain != gain { inputGain = gain }
        if outputVolume != volume { outputVolume = volume }
        if inputMuted != micMute { inputMuted = micMute }
        if outputMuted != speakerMute { outputMuted = speakerMute }
    }

    public func setInputGain(_ value: Double) { changeLevel(value, on: input) }
    public func setOutputVolume(_ value: Double) { changeLevel(value, on: output) }
    public func setInputMuted(_ value: Bool) { changeMute(value, on: input) }
    public func setOutputMuted(_ value: Bool) { changeMute(value, on: output) }

    private func changeLevel(_ value: Double, on device: RouteDevice?) {
        guard running else { return }
        guard let device, let e = endpoint(device), CoreAudioProperties.setVolume(value, for: e) else {
            lastError = "The audio device could not change its level."
            refresh()
            return
        }
        lastError = nil
        refreshLevels()
    }

    private func changeMute(_ value: Bool, on device: RouteDevice?) {
        guard running, let device, let e = endpoint(device), CoreAudioProperties.isCurrent(e) else { return }
        let native = CoreAudioProperties.mute(e)
        let saved = preferences.levelsBeforeMute[device.id]
        if let native, native != value {
            guard CoreAudioProperties.setMute(value, for: e) else {
                lastError = "The audio device could not change its mute setting."
                return
            }
        }
        // A driver may gain a native mute after a service restart. Unmute
        // must still restore a previously zeroed software gain.
        if native == nil || (!value && saved != nil) {
            guard let current = CoreAudioProperties.volume(e) else {
                lastError = "This device does not expose a writable gain control."
                return
            }
            guard gainMute.set(value, id: device.id, current: current, saved: saved,
                               save: { storeLevelBeforeMute($0, for: device.id) },
                               write: { CoreAudioProperties.setVolume($0, for: e) }) else {
                lastError = value ? "The audio device could not mute." : "The audio device could not restore its level."
                return
            }
        }
        lastError = nil
        refreshLevels()
    }

    public func move(_ device: RouteDevice, by offset: Int) {
        let before = preferences
        guard preferences.move(device, by: offset, in: device.role == .input ? inputs : outputs) else { return }
        policies[device.role]?.heldID = nil
        persistIfChanged(since: before)
        if let snapshot { apply(snapshot) }
    }

    public func setHidden(_ hidden: Bool, for device: RouteDevice) {
        let before = preferences
        preferences.setHidden(hidden, device: device)
        if hidden, policies[device.role]?.heldID == device.id { policies[device.role]?.heldID = nil }
        persistIfChanged(since: before)
        if let snapshot { apply(snapshot) }
    }

    @discardableResult public func importLegacyPreferences() -> Bool {
        let domain = defaults.persistentDomain(forName: "app.audioprioritybar") ?? [:]
        guard preferences.importLegacy(domain) else {
            lastError = preferences.importedLegacy ? "Audio preferences have already been imported." : "No saved audio priorities or hidden devices were found."
            return false
        }
        canImportLegacyPreferences = false
        lastError = nil
        save()
        if let snapshot { apply(snapshot) }
        return true
    }

    private func storeLevelBeforeMute(_ level: Double?, for id: String) {
        guard preferences.levelsBeforeMute[id] != level else { return }
        preferences.levelsBeforeMute[id] = level
        save()
    }

    private func persistIfChanged(since previous: RoutePreferences) {
        preferences.inputHold = policies[.input]?.heldID
        preferences.outputHold = policies[.output]?.heldID
        if preferences != previous { save() }
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(encoded, forKey: Self.preferenceKey)
    }
}
