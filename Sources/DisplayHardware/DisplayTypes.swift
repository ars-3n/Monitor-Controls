import CoreGraphics
import Foundation

public struct MonitorDisplay: Identifiable, Equatable, Sendable {
    public let id: String
    public let screenID: CGDirectDisplayID
    public let name: String
    public let canRememberPairing: Bool
    public internal(set) var brightness: Double?
    public internal(set) var volume: Double?
    public internal(set) var muted: Bool?
    /// The monitor has no mute of its own that works, so silence is volume zero.
    public internal(set) var mutesByVolume = false

    public init(id: String, screenID: CGDirectDisplayID, name: String,
                canRememberPairing: Bool = true, brightness: Double?, volume: Double?, muted: Bool?) {
        self.id = id
        self.screenID = screenID
        self.name = name
        self.canRememberPairing = canRememberPairing
        self.brightness = brightness
        self.volume = volume
        self.muted = muted
    }
}

enum Feature: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case volume = 0x62
    case mute = 0x8D
    var isAudio: Bool { self != .brightness }
}

struct DDCValue: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16

    enum Reply { case value(DDCValue), unsupported, invalid }

    static func parse(_ bytes: [UInt8], for feature: Feature, allowsLGQuirk: Bool) -> Reply {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[2] == 2,
              bytes[4] == feature.rawValue,
              bytes[1] == 0x88 || (allowsLGQuirk && bytes[1] == 0) else { return .invalid }
        // Some LG ULTRAWIDE replies contain a zero length byte, yet retain the
        // checksum for 0x88. Keep every other header and checksum check intact.
        let checksum = bytes[2..<10].reduce(UInt8(0x50 ^ 0x6e ^ 0x88), ^)
        guard bytes[10] == checksum else { return .invalid }
        if bytes[3] == 1 { return .unsupported }
        guard bytes[3] == 0 else { return .invalid }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        if feature == .mute {
            guard current == 1 || current == 2 else { return .invalid }
        } else {
            guard maximum > 0, current <= maximum else { return .invalid }
        }
        return .value(Self(current: current, maximum: maximum))
    }

    static func confirmed(_ observed: Self?, target: UInt16, feature: Feature, lg: Bool) -> Bool {
        guard let observed else { return false }
        if observed.current == target { return true }
        // This LG reports 18 for a request of 17, and correctly applies 16.
        // Preserve the observed value in the UI; tolerate only a single unit
        // of its 0…100 speaker scale. Brightness and mute still match exactly.
        return lg && feature == .volume && observed.maximum == 100 &&
            abs(Int(observed.current) - Int(target)) == 1
    }

    var fraction: Double { Double(current) / Double(maximum) }
}

extension MonitorDisplay {
    func value(_ feature: Feature) -> Double? {
        switch feature {
        case .brightness: brightness
        case .volume: volume
        case .mute: muted.map { $0 ? 1 : 0 }
        }
    }

    mutating func apply(_ value: Double?, to feature: Feature) {
        switch feature {
        case .brightness: brightness = value
        case .volume:
            volume = value
            if mutesByVolume, let value { muted = value == 0 }
        case .mute:
            muted = value.map { $0 != 0 }
            if mutesByVolume, value == 1 { volume = 0 }
        }
    }
}
