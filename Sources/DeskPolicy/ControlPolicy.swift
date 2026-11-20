import CoreGraphics
import Foundation

/// Display names are only a fallback. Never discard digits or guess between identical monitors.
public struct DisplayCandidate: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum OutputPairing {
    public static func resolve(
        outputName: String, connectedDisplayOutputNames: [String], monitors: [DisplayCandidate], preferredID: String?
    ) -> String? {
        if let preferredID {
            return monitors.first { $0.id == preferredID }?.id
        }
        let expected = normalized(outputName)
        guard !expected.isEmpty, connectedDisplayOutputNames.filter({ normalized($0) == expected }).count == 1 else {
            return nil
        }
        let matches = monitors.filter { normalized($0.name) == expected }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func normalized(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum DeskKey: Int, Hashable, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// NSScreen frames and NSEvent.mouseLocation use the same global coordinate space.
public struct DisplayPlacement {
    public let screenID: UInt32
    public let frame: CGRect
    public init(screenID: UInt32, frame: CGRect) { self.screenID = screenID; self.frame = frame }

    public static func atPointer(_ point: CGPoint, screens: [Self]) -> UInt32? {
        screens.first { $0.frame.contains(point) }?.screenID
    }
}

public struct MediaPress: Equatable, Sendable {
    public let key: DeskKey
    public let isDown: Bool
    public let isRepeat: Bool

    public init?(data: Int) {
        guard let key = DeskKey(rawValue: (data >> 16) & 0xffff) else { return nil }
        let state = (data >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        self.key = key
        self.isDown = state == 0x0a
        self.isRepeat = data & 1 != 0
    }
}

public enum KeyDisposition: Equatable, Sendable {
    case passThrough, consume, adjust(String)
}

public enum KeyTarget: Equatable, Sendable {
    case system, unavailable, monitor(String)

    public static func brightness(external: Bool, controllableID: String?) -> Self {
        guard external else { return .system }
        return controllableID.map(Self.monitor) ?? .unavailable
    }
}

/// A held key belongs to the device that received its first press. Never send its
/// tail to a newly connected output or to a monitor the pointer just entered.
public struct PressTracker {
    private var held: [DeskKey: KeyTarget] = [:]
    public init() {}
    public mutating func reset() { held.removeAll() }

    public mutating func disposition(for press: MediaPress, target: KeyTarget) -> KeyDisposition {
        if !press.isDown {
            return held.removeValue(forKey: press.key) == nil ? .passThrough : .consume
        }
        if press.isRepeat {
            guard let original = held[press.key] else { return .passThrough }
            if original == target, case let .monitor(id) = original, press.key != .mute { return .adjust(id) }
            return .consume
        }
        held[press.key] = target == .system ? nil : target
        switch target {
        case .system: return .passThrough
        case .unavailable: return .consume
        case let .monitor(id): return .adjust(id)
        }
    }
}
