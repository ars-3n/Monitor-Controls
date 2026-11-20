import Foundation

/// Some devices implement mute through a gain change, and their gain getter
/// can still return the old value after a successful HAL write. Keep the
/// durable restore value until the hardware confirms zero or an independent
/// change supersedes the operation.
@MainActor final class GainMuteRecovery {
    private var awaitingZero: [String: Double] = [:]

    func isMuted(id: String, current: Double, saved: Double?, save: (Double?) -> Void) -> Bool {
        guard saved != nil else { awaitingZero[id] = nil; return false }
        if current == 0 {
            awaitingZero[id] = nil
            return true
        }
        if awaitingZero[id] != current {
            awaitingZero[id] = nil
            save(nil)
        }
        return false
    }

    func set(_ muted: Bool, id: String, current: Double, saved: Double?,
             save: (Double?) -> Void, write: (Double) -> Bool) -> Bool {
        if muted {
            if current == 0, saved != nil { return true }
            let previousPending = awaitingZero[id]
            awaitingZero[id] = current
            save(current)
            guard write(0) else {
                awaitingZero[id] = previousPending
                save(saved)
                return false
            }
        } else if let saved {
            // Queue a restoring write even when a previous mute is still in
            // flight and the getter hasn't changed yet.
            if current == 0 || awaitingZero[id] != nil {
                guard write(saved) else { return false }
            }
            awaitingZero[id] = nil
            save(nil)
        }
        return true
    }
}
