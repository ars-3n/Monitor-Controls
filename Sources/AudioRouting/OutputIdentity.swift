import Foundation

/// Epoch invalidation catches A → B → A and a daemon restart that reuses
/// both an object ID and UID. The HAL check runs outside the lock.
final class OutputIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var objectID: UInt32?
    private var uid: String?
    private var epoch: UInt64 = 0

    func update(objectID: UInt32?, uid: String?) -> Bool {
        lock.withLock {
            guard self.objectID != objectID || self.uid != uid else { return false }
            self.objectID = objectID
            self.uid = uid
            epoch &+= 1
            return true
        }
    }

    func invalidate() {
        lock.withLock {
            objectID = nil
            uid = nil
            epoch &+= 1
        }
    }

    func guardFor(_ endpoint: Endpoint, checkLive: @escaping @Sendable () -> Bool) -> (@Sendable () -> Bool)? {
        let ticket: UInt64? = lock.withLock {
            guard objectID == endpoint.objectID, uid == endpoint.uid else { return nil }
            return epoch
        }
        guard let ticket else { return nil }
        return { [self] in
            lock.withLock { ticket == epoch } && checkLive() && lock.withLock { ticket == epoch }
        }
    }
}
