import AppKit
import CoreGraphics
import DisplayBridge
import IOKit

struct ScreenDescription: Sendable {
    let screenID: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    let uuid: String?
    let location: String?

    @MainActor
    static func collect() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  CGDisplayIsBuiltin(screenID) == 0 else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(screenID)?.takeRetainedValue()
            return Self(screenID: screenID, name: screen.localizedName, vendor: CGDisplayVendorNumber(screenID),
                        product: CGDisplayModelNumber(screenID), serial: CGDisplaySerialNumber(screenID),
                        uuid: uuid.map { CFUUIDCreateString(nil, $0) as String },
                        location: nil)
        }
    }

    func resolvingLocation() -> Self {
        let info = MCCopyDisplayInfo(screenID) as NSDictionary?
        return Self(screenID: screenID, name: name, vendor: vendor, product: product, serial: serial,
                    uuid: uuid, location: info?[kIODisplayLocationKey] as? String)
    }
}

struct ServiceIdentity {
    let productName: String
    let framebufferPath: String
    let serial: UInt32

    // Name-only matching requires uniqueness in both directions.
    func score(for screen: ScreenDescription) -> Int {
        // A dock may reuse its framebuffer path before the old DDC proxy
        // disappears. A contradictory physical serial rules that proxy out.
        if serial != 0 && screen.serial != 0 && serial != screen.serial { return 0 }
        if let location = screen.location, !location.isEmpty {
            if location == framebufferPath { return 3 }
            if location.hasPrefix("IOService:") && framebufferPath.hasPrefix("IOService:") { return 0 }
        }
        guard productName.caseInsensitiveCompare(screen.name) == .orderedSame else { return 0 }
        if serial != 0 && screen.serial != 0 { return 2 }
        return 1
    }

    static func matches(screens: [ScreenDescription], services: [ServiceIdentity]) -> [Int: Int] {
        let scores = screens.map { screen in services.map { $0.score(for: screen) } }
        let bestForScreen = scores.map { $0.max() ?? 0 }
        let bestForService = services.indices.map { index in scores.map { $0[index] }.max() ?? 0 }
        var matches: [Int: Int] = [:]
        var consumed: Set<Int> = []
        for rank in stride(from: 3, through: 1, by: -1) {
            let candidates = screens.indices.filter { matches[$0] == nil && bestForScreen[$0] == rank }.map { i in
                (i, services.indices.filter { !consumed.contains($0) && scores[i][$0] == rank && bestForService[$0] == rank })
            }
            for (screen, options) in candidates where options.count == 1 {
                let service = options[0]
                guard candidates.filter({ $0.1.contains(service) }).count == 1 else { continue }
                matches[screen] = service
                consumed.insert(service)
            }
        }
        return matches
    }
}

private func registryProperty(_ entry: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, nil, 0)?.takeRetainedValue()
}

private func registryPath(_ entry: io_service_t) -> String? {
    var path = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
    guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return nil }
    return path.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
}

private func forEachService(_ name: String, visit: (io_service_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        visit(entry)
        IOObjectRelease(entry)
    }
}

protocol DDCChannel: AnyObject {
    func read(_ feature: Feature) -> [UInt8]?
    func write(_ feature: Feature, value: UInt16) -> Bool
}

final class Channel: DDCChannel {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    func read(_ feature: Feature) -> [UInt8]? {
        var reply = [UInt8](repeating: 0, count: 11)
        return MCReadFeature(handle, feature.rawValue, &reply) ? reply : nil
    }

    func write(_ feature: Feature, value: UInt16) -> Bool {
        MCWriteFeature(handle, feature.rawValue, value)
    }

    deinit { MCCloseChannel(handle) }
}

private struct Service {
    let identity: ServiceIdentity
    let channel: Channel
}

private func appleSiliconServices() -> [Service] {
    var framebuffers: [String: [ServiceIdentity]] = [:]
    for driver in ["AppleCLCD2", "IOMobileFramebufferShim"] {
        forEachService(driver) { entry in
            guard let path = registryPath(entry),
                  let parent = path.split(separator: "/").dropLast().last,
                  let port = parent.split(separator: "@").first,
                  let attributes = registryProperty(entry, "DisplayAttributes") as? NSDictionary,
                  let product = attributes["ProductAttributes"] as? NSDictionary,
                  let name = product["ProductName"] as? String else { return }
            let identity = ServiceIdentity(productName: name, framebufferPath: path,
                                          serial: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0)
            if framebuffers[String(port), default: []].contains(where: { $0.framebufferPath == path }) == false {
                framebuffers[String(port), default: []].append(identity)
            }
        }
    }
    var services: [Service] = []
    forEachService("DCPAVServiceProxy") { entry in
        guard registryProperty(entry, "Location") as? String == "External", let path = registryPath(entry),
              let endpoint = path.split(separator: "/").dropLast().last,
              let port = endpoint.split(separator: ":").first,
              let identities = framebuffers[String(port)], identities.count == 1,
              let channel = MCOpenARMChannel(entry) else { return }
        services.append(Service(identity: identities[0], channel: Channel(channel)))
    }
    return services
}

struct Endpoint {
    let display: MonitorDisplay
    let channel: (any DDCChannel)?
    let allowsLGQuirk: Bool
    let appleBrightness: Bool
    var readings: [Feature: DDCValue] = [:]
}

enum Discovery {
    static func endpoints(_ connected: [ScreenDescription]) -> [Endpoint] {
        var seen: Set<CGDirectDisplayID> = []
        let distinct = connected.filter { seen.insert($0.screenID).inserted }
        guard !distinct.isEmpty else { return [] }
        #if arch(arm64)
        // CoreDisplay metadata can involve a synchronous IPC. Only NSScreen
        // enumeration runs on the main actor.
        let screens = distinct.map { $0.resolvingLocation() }
        let services = appleSiliconServices()
        let matches = ServiceIdentity.matches(screens: screens, services: services.map(\.identity))
        #else
        let screens = distinct
        #endif
        return screens.enumerated().map { index, screen in
            #if arch(arm64)
            let service = matches[index].map { services[$0] }
            let channel = service?.channel
            #else
            let channel = MCOpenIntelChannel(screen.screenID).map(Channel.init)
            #endif
            let identity = stableID(for: screen, among: screens)
            let display = MonitorDisplay(id: identity.id, screenID: screen.screenID, name: screen.name,
                                         canRememberPairing: identity.persistent, brightness: nil, volume: nil, muted: nil)
            return Endpoint(display: display, channel: channel,
                            allowsLGQuirk: screen.name.caseInsensitiveCompare("LG ULTRAWIDE") == .orderedSame,
                            appleBrightness: screen.vendor == 0x0610)
        }
    }

    static func stableID(for screen: ScreenDescription, among screens: [ScreenDescription]) -> (id: String, persistent: Bool) {
        let model = "\(screen.vendor)-\(screen.product)"
        let same = screens.filter { $0.vendor == screen.vendor && $0.product == screen.product && $0.serial == screen.serial }
        if screen.serial != 0 && same.count == 1 { return ("\(model)-s\(screen.serial)", true) }
        // Two serial-less monitors can still have distinct Core Graphics UUIDs.
        // Keep their identity stable when either monitor connects or disconnects.
        if screen.serial == 0, let uuid = screen.uuid, !uuid.isEmpty,
           uuid != "00000000-0000-0000-0000-000000000000",
           same.filter({ $0.uuid == uuid }).count == 1 {
            return ("\(model)-u\(uuid)", true)
        }
        // Same-model panels can report identical serials and display UUIDs.
        // A live CG identifier distinguishes them only until reconfiguration.
        return ("\(model)-session-\(screen.screenID)", false)
    }
}
