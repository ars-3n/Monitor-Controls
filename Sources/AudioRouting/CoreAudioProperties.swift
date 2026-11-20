// Adapted from Audio Priority Bar (GPL-3.0).
import AudioToolbox
import CoreAudio
import Foundation
import IOKit

enum CoreAudioProperties {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    static func deviceIDs() -> [AudioObjectID]? {
        objectIDs(system, selector: kAudioHardwarePropertyDevices)
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    static func defaultDevice(_ role: RouteRole) -> AudioObjectID? {
        let selector = role == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var id = AudioObjectID(0)
        guard read(system, selector: selector, into: &id) == noErr,
              id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }

    static func setDefault(_ id: AudioObjectID, role: RouteRole) -> Bool {
        let selector = role == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var id = id
        return write(system, selector: selector, value: &id) == noErr
    }


    static func inventory() -> [Endpoint]? {
        deviceIDs()?.flatMap { id -> [Endpoint] in
            guard let uid = deviceUID(id),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return [] }
            let transport = transport(id)
            let port = PortIdentity(uid)
            let isDisplay = transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
            var followsPort: Bool? = false
            if transport == kAudioDeviceTransportTypeUSB, let location = port?.usbLocation {
                followsPort = isSeriallessUSBDevice(uid: uid, at: location)
            } else if isDisplay, port?.usbLocation == nil, port != nil {
                followsPort = true
            }
            return RouteRole.allCases.compactMap { role in
                guard !streams(id, scope: role.scope).isEmpty else { return nil }
                return Endpoint(objectID: id, uid: uid, name: name, role: role,
                                isDisplay: isDisplay && role == .output,
                                isVirtual: transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate,
                                followsPort: followsPort)
            }
        }
    }

    // The default can change between rendering a slider and dispatching its action.
    static func isCurrent(_ endpoint: Endpoint) -> Bool {
        defaultDevice(endpoint.role) == endpoint.objectID && deviceUID(endpoint.objectID) == endpoint.uid
    }

    static func volume(_ endpoint: Endpoint) -> Double? {
        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        let scope = endpoint.role.scope
        guard isSettable(endpoint.objectID, selector, scope: scope) else { return nil }
        var value: Float32 = 0
        guard read(endpoint.objectID, selector: selector, scope: scope, into: &value) == noErr, value.isFinite else { return nil }
        return Double(min(1, max(0, value)))
    }

    static func setVolume(_ value: Double, for endpoint: Endpoint) -> Bool {
        guard value.isFinite, isCurrent(endpoint) else { return false }
        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        guard isSettable(endpoint.objectID, selector, scope: endpoint.role.scope) else { return false }
        var level = Float32(min(1, max(0, value)))
        return write(endpoint.objectID, selector: selector, scope: endpoint.role.scope, value: &level) == noErr
    }

    static func mute(_ endpoint: Endpoint) -> Bool? {
        let scope = endpoint.role.scope
        guard let element = wholeDeviceMuteElement(endpoint.objectID, scope: scope) else { return nil }
        var value: UInt32 = 0
        return read(endpoint.objectID, selector: kAudioDevicePropertyMute, scope: scope, element: element, into: &value) == noErr ? value != 0 : nil
    }

    static func setMute(_ muted: Bool, for endpoint: Endpoint) -> Bool {
        let scope = endpoint.role.scope
        guard isCurrent(endpoint), let element = wholeDeviceMuteElement(endpoint.objectID, scope: scope) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return write(endpoint.objectID, selector: kAudioDevicePropertyMute, scope: scope, element: element, value: &value) == noErr
    }

    private static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Bool {
        var address = property(selector, scope: scope)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }
    private static func wholeDeviceMuteElement(
        _ id: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyElement? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = property(kAudioDevicePropertyMute, scope: scope, element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            // A mute on channel 1 leaves the rest of a multi-channel interface live.
            if element == kAudioObjectPropertyElementMain || hasSingleChannel(id, scope: scope) {
                return element
            }
        }
        return nil
    }

    private static func hasSingleChannel(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        let ids = streams(id, scope: scope)
        guard ids.count == 1, let stream = ids.first else { return false }
        var format = AudioStreamBasicDescription()
        return read(stream, selector: kAudioStreamPropertyVirtualFormat, into: &format) == noErr
            && format.mChannelsPerFrame == 1
    }

    private static func objectIDs(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID]? {
        var address = property(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        let capacity = size
        guard capacity.isMultiple(of: stride) else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(capacity / stride))
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr, size <= capacity, size.isMultiple(of: stride) else { return nil }
        return Array(ids.prefix(Int(size / stride)))
    }

    /// The registry can lag behind the audio driver. An absent descriptor
    /// leaves identity unresolved until a later enumeration.
    private static func isSeriallessUSBDevice(uid: String, at location: UInt32) -> Bool? {
        let parts = uid.components(separatedBy: ":")
        guard parts.count == 5 else { return nil }
        func matches(_ properties: [String: Any]) -> Bool {
            guard let request = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
            var fields = properties
            fields["USB Vendor Name"] = parts[1]
            fields["USB Product Name"] = parts[2]
            request[kIOPropertyMatchKey] = fields
            let service = IOServiceGetMatchingService(kIOMainPortDefault, request)
            guard service != IO_OBJECT_NULL else { return false }
            IOObjectRelease(service)
            return true
        }
        if matches(["USB Serial Number": parts[3]]) { return false }
        if matches(["locationID": location, "iSerialNumber": 0]) { return true }
        return nil
    }

    private static func transport(_ id: AudioObjectID) -> UInt32 {
        var transport = UInt32(0)
        guard read(
            id,
            selector: kAudioDevicePropertyTransportType,
            into: &transport
        ) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return transport
    }

    private static func streams(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        objectIDs(id, selector: kAudioDevicePropertyStreams, scope: scope) ?? []
    }

    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: Unmanaged<CFString>?
        var address = property(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        )
        guard status == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func read<T: BitwiseCopyable>(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        into value: inout T
    ) -> OSStatus {
        var address = property(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        )
    }

    private static func write<T: BitwiseCopyable>(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: inout T
    ) -> OSStatus {
        var address = property(selector, scope: scope, element: element)
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        )
    }

    private static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}

extension RouteRole {
    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }
}
