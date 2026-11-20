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

    static func decode(_ bytes: [UInt8], for feature: Feature, allowsLGQuirk: Bool) -> Self? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[2] == 2, bytes[3] == 0,
              bytes[4] == feature.rawValue,
              bytes[1] == 0x88 || (allowsLGQuirk && bytes[1] == 0) else { return nil }
        // Some LG ULTRAWIDE replies contain a zero length byte, yet retain the
        // checksum for 0x88. Keep every other header and checksum check intact.
        let checksum = bytes[2..<10].reduce(UInt8(0x50 ^ 0x6e ^ 0x88), ^)
        guard bytes[10] == checksum else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        if feature == .mute {
            guard current == 1 || current == 2 else { return nil }
        } else {
            guard maximum > 0, current <= maximum else { return nil }
        }
        return Self(current: current, maximum: maximum)
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
        case .volume: volume = value
        case .mute: muted = value.map { $0 != 0 }
        }
    }
}
