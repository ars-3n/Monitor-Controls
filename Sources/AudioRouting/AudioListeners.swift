import AudioToolbox
import CoreAudio
import Foundation

enum AudioEvent { case topology, defaults, levels, restart }

private struct Subscription: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    var scope = kAudioObjectPropertyScopeGlobal
    var element = kAudioObjectPropertyElementMain
    func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

// Block-based HAL subscriptions retain their closures until removal. The
// registration owns its exact block and queue so teardown is symmetric.
private final class AudioObservation {
    let key: Subscription
    let block: AudioObjectPropertyListenerBlock

    init?(_ key: Subscription, receive: @escaping @MainActor () -> Void) {
        self.key = key
        self.block = { _, _ in MainActor.assumeIsolated { receive() } }
        var address = key.address()
        guard AudioObjectHasProperty(key.object, &address),
              AudioObjectAddPropertyListenerBlock(key.object, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        var address = key.address()
        AudioObjectRemovePropertyListenerBlock(key.object, &address, .main, block)
    }
}

@MainActor final class AudioListeners {
    var receive: ((AudioEvent) -> Void)?
    private var system: [Subscription: AudioObservation] = [:]
    private var levels: [Subscription: AudioObservation] = [:]
    private var levelEndpoints: [RouteRole: Endpoint] = [:]
    private var generation = 0

    func attachSystem() -> Bool {
        let object = AudioObjectID(kAudioObjectSystemObject)
        let specs: [(AudioObjectPropertySelector, AudioEvent)] = [
            (kAudioHardwarePropertyDevices, .topology), (kAudioHardwarePropertyDefaultInputDevice, .defaults),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaults), (kAudioHardwarePropertyServiceRestarted, .restart)
        ]
        for (selector, event) in specs {
            let key = Subscription(object: object, selector: selector)
            if system[key] == nil {
                let epoch = generation
                system[key] = AudioObservation(key) { [weak self] in
                    guard let self, generation == epoch else { return }
                    receive?(event)
                }
            }
        }
        return system.count == specs.count
    }

    func watch(_ endpoints: [Endpoint]) {
        let fresh = Dictionary(endpoints.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first })
        // Platform IDs may be recycled on USB wake. Rebind even if all
        // numeric addresses appear unchanged but the device UID differs.
        for (role, previous) in levelEndpoints where previous.uid != fresh[role]?.uid || previous.objectID != fresh[role]?.objectID {
            levels = levels.filter { $0.key.object != previous.objectID || $0.key.scope != role.scope }
        }
        levelEndpoints = fresh
        var keys: Set<Subscription> = []
        for endpoint in endpoints {
            let scope = endpoint.role.scope
            keys.insert(Subscription(object: endpoint.objectID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope))
            keys.insert(Subscription(object: endpoint.objectID, selector: kAudioDevicePropertyMute, scope: scope))
            keys.insert(Subscription(object: endpoint.objectID, selector: kAudioDevicePropertyMute, scope: scope, element: 1))
        }
        levels = levels.filter { keys.contains($0.key) }
        for key in keys where levels[key] == nil {
            let epoch = generation
            levels[key] = AudioObservation(key) { [weak self] in
                guard let self, generation == epoch else { return }
                receive?(.levels)
            }
        }
    }

    func stop() {
        generation += 1
        system.removeAll()
        levels.removeAll()
        levelEndpoints.removeAll()
    }
}
