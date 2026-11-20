import AppKit
import ApplicationServices
import DeskPolicy

@MainActor
final class MediaKeys {
    var target: (DeskKey) -> KeyTarget = { _ in .system }
    var adjust: (DeskKey, String, Bool) -> Void = { _, _, _ in }
    private var tracker = PressTracker()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var active: Bool { port != nil }

    func start() -> Bool {
        if active { return true }
        let systemDefined = UInt32(NSEvent.EventType.systemDefined.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue()
            // The source is installed only on the main run loop.
            let swallow = MainActor.assumeIsolated { owner.handle(type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << systemDefined, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
        tracker.reset()
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tracker.reset()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
              let press = MediaPress(data: ns.data1) else { return false }

        let modifiers = ns.modifierFlags.intersection([.command, .control, .option, .shift])
        let fine = modifiers == [.option, .shift]
        let eligible = modifiers.isEmpty || fine
        let destination = eligible && press.isDown ? target(press.key) : .system
        switch tracker.disposition(for: press, target: destination) {
        case .passThrough: return false
        case .consume: return true
        case let .adjust(id):
            adjust(press.key, id, fine)
            return true
        }
    }
}
