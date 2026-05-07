import Foundation

/// Nonreentrant async boundary for `FileLogStore` operation
/// critical sections.
///
/// `FileLogStore`'s actor isolation serializes calls between
/// suspension points but releases at every `await`, so a
/// reentrant call can interleave with an in-flight operation
/// when its body awaits — including when an in-body test seam
/// awaits a continuation. This boundary holds **across** every
/// `await` inside the operation body so `append`, `flush`,
/// `exportLogs(to:)`, and `removeExportedLogs()` cannot
/// interleave with one another, even when the body suspends.
///
/// Acquisition mints a unique ``Lease`` that the caller passes
/// back to ``exit(_:)``. The lease check distinguishes the
/// current holder from a hand-off-pending successor: a stale
/// double-`exit` from a previous holder cannot match the
/// current lease and therefore cannot drop the boundary while
/// a hand-off is in flight. ``enter()`` suspends asynchronously
/// while the boundary is held; the next holder is granted in
/// FIFO order. ``exit(_:)`` runs synchronously so it composes
/// with `defer { … }` cleanup at every return path of the
/// operation.
internal final class OperationBoundary: @unchecked Sendable {
    /// Opaque token identifying a single boundary acquisition.
    /// `enter()` mints one; `exit(_:)` releases the matching
    /// lease. A mismatched release returns `false` and
    /// preserves the boundary's current holder, so a stale or
    /// duplicate `exit` cannot hand the boundary to a queued
    /// waiter twice.
    internal struct Lease: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Lease, Never>
    }

    private let lock = NSLock()
    private var nextLeaseID: UInt64 = 0
    private var currentHolder: UInt64?
    /// FIFO queue of waiters with a head index so dequeues run
    /// in O(1) amortized instead of O(n) (`removeFirst()`
    /// shifts the whole array). Slots vacated by dequeued
    /// waiters are nilled out so resumed continuations are not
    /// retained, and the storage is compacted periodically.
    private var waiters: [Waiter?] = []
    private var waiterHead = 0

    /// Acquires the boundary, suspending the caller until the
    /// previous holder calls ``exit(_:)`` with its matching
    /// lease. The returned ``Lease`` must be passed back to
    /// ``exit(_:)`` to release the boundary.
    ///
    /// Waiting is intentionally non-cancelable: task
    /// cancellation does not remove a queued operation from
    /// the FIFO. Callers that enter the boundary still
    /// receive their lease in order and are responsible for
    /// deciding whether the operation body observes
    /// cancellation.
    func enter() async -> Lease {
        await withCheckedContinuation { cont in
            lock.lock()
            nextLeaseID += 1
            let id = nextLeaseID
            if currentHolder == nil {
                currentHolder = id
                lock.unlock()
                cont.resume(returning: Lease(id: id))
            } else {
                enqueueWaiter(Waiter(id: id, continuation: cont))
                lock.unlock()
            }
        }
    }

    /// Releases the boundary if `lease` matches the current
    /// holder. Returns `true` on a matching release; returns
    /// `false` on a mismatched lease — stale double-`exit`
    /// from a previous holder, or release before the matching
    /// ``enter()`` returned — and preserves the current
    /// holder. The bool result lets call sites surface the
    /// invariant violation without a process-killing
    /// crash-path while keeping the boundary state correct.
    ///
    /// On hand-off, the current holder is atomically set to
    /// the next waiter's lease **before** the continuation
    /// resumes. A stale `exit` from the previous holder
    /// therefore cannot match the new lease and cannot drop
    /// the boundary out from under the successor.
    func exit(_ lease: Lease) -> Bool {
        lock.lock()
        guard currentHolder == lease.id else {
            lock.unlock()
            return false
        }
        if let next = dequeueWaiter() {
            currentHolder = next.id
            lock.unlock()
            next.continuation.resume(returning: Lease(id: next.id))
        } else {
            currentHolder = nil
            lock.unlock()
        }
        return true
    }

    private func enqueueWaiter(_ waiter: Waiter) {
        waiters.append(waiter)
    }

    private func dequeueWaiter() -> Waiter? {
        while waiterHead < waiters.count {
            defer { waiterHead += 1 }
            if let waiter = waiters[waiterHead] {
                waiters[waiterHead] = nil
                compactWaitersIfNeeded()
                return waiter
            }
        }
        compactWaitersIfNeeded()
        return nil
    }

    private func compactWaitersIfNeeded() {
        if waiterHead > 64, waiterHead * 2 >= waiters.count {
            waiters.removeFirst(waiterHead)
            waiterHead = 0
        }
    }

    /// TEST-ONLY: number of waiters currently queued behind the
    /// holder. Lets tests deterministically wait until a known
    /// queue depth has been reached before driving hand-off
    /// proofs. Counts only non-nil slots from the head onward,
    /// so vacated tail slots do not inflate the reported queue
    /// depth. Uses an explicit guarded loop so the helper does
    /// not rely on slice-on-end-index behavior.
    internal func pendingWaiterCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        var index = waiterHead
        while index < waiters.count {
            if waiters[index] != nil {
                count += 1
            }
            index += 1
        }
        return count
    }
}
