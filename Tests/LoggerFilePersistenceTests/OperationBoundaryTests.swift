import Testing

@testable import LoggerFilePersistence

/// Coverage for `OperationBoundary` — the nonreentrant async
/// boundary that wraps every `FileLogStore` operation. Pins
/// the lease-match invariant so `exit(_:)`'s `false` return
/// path is not a dead contract.
@Suite("OperationBoundary lease-match invariant")
struct OperationBoundaryTests {
    /// Bounded poll until the boundary's pending-waiter count
    /// reaches `target`. Lets multi-waiter tests register
    /// queued waiters one at a time so FIFO order is
    /// determined by the deterministic `enter()` sequence,
    /// not by task creation order.
    fileprivate static func waitForPendingWaiterCount(
        _ boundary: OperationBoundary,
        _ target: Int
    ) async throws {
        try await withTestTimeout(.seconds(5)) {
            while boundary.pendingWaiterCountForTesting() != target {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

// MARK: - exit mismatch

extension OperationBoundaryTests {
    @Test(
        "exit with a lease that does not match the current holder returns false"
    )
    func exitWithMismatchedLeaseReturnsFalse() async {
        let boundary = OperationBoundary()
        let lease = await boundary.enter()

        // First exit matches the current holder; should release
        // the boundary and return true.
        #expect(boundary.exit(lease))
        // Second exit reuses the now-stale lease; the boundary
        // is no longer held by it. Must return false and not
        // disturb the (free) boundary state.
        #expect(!boundary.exit(lease))
    }

    @Test(
        "Stale exit during hand-off cannot release the successor's boundary"
    )
    func staleExitDuringHandoffPreservesSuccessor() async throws {
        let boundary = OperationBoundary()
        let leaseA = await boundary.enter()
        // Per-lease cleanup defer: registered immediately
        // after each lease is captured, so a failure-path
        // exit always releases the actual current holder.
        // `exit` on a stale lease is a benign no-op.
        defer { _ = boundary.exit(leaseA) }

        // Spawn B that queues behind A. Task spawn order does
        // not imply enqueue order; we wait for B to be
        // deterministically registered before exiting A.
        let bAcquired = TestRendezvous()
        let bTask = Task {
            let leaseB = await boundary.enter()
            await bAcquired.signalPaused()
            return leaseB
        }
        defer { bTask.cancel() }

        let cAcquired = TestRendezvous()
        var cTaskHandle: Task<OperationBoundary.Lease, Never>?
        defer { cTaskHandle?.cancel() }

        try await Self.waitForPendingWaiterCount(boundary, 1)

        // A releases → B becomes the holder. The `awaitPaused`
        // wait is the only fallible step here; once it
        // returns, B has executed `signalPaused()` and is one
        // statement away from returning `leaseB`, so the
        // following `await bTask.value` cannot meaningfully
        // race the cleanup window.
        #expect(boundary.exit(leaseA))
        try await withTestTimeout(.seconds(30)) {
            await bAcquired.awaitPaused()
        }
        let leaseB = await bTask.value
        defer { _ = boundary.exit(leaseB) }

        // A's now-stale lease must not match the new holder.
        #expect(!boundary.exit(leaseA))

        // Spawn C now — B holds the boundary, so C will queue.
        let cTask = Task {
            let leaseC = await boundary.enter()
            await cAcquired.signalPaused()
            return leaseC
        }
        cTaskHandle = cTask
        try await Self.waitForPendingWaiterCount(boundary, 1)

        // State-based proof: C is parked, not holding. A buggy
        // stale exit that released the boundary would have let
        // C acquire (count → 0, cAcquired signaled).
        #expect(boundary.pendingWaiterCountForTesting() == 1)
        #expect(!(await cAcquired.isPausedSignaled()))

        // Release B → C becomes the holder.
        #expect(boundary.exit(leaseB))
        try await withTestTimeout(.seconds(30)) {
            await cAcquired.awaitPaused()
        }
        let leaseC = await cTask.value
        defer { _ = boundary.exit(leaseC) }

        // C's matching exit closes the boundary cleanly; a
        // repeat exit is a stale mismatch. The trailing
        // `defer` exit on `leaseC` is then a benign no-op.
        #expect(boundary.exit(leaseC))
        #expect(!boundary.exit(leaseC))
    }
}

// MARK: - FIFO hand-off across multiple queued waiters

extension OperationBoundaryTests {
    // swiftlint:disable function_body_length
    // Reason: Three deterministic FIFO hand-off legs (A→B, B→C, C→D) plus per-leg pre-release proofs and cleanup-on-failure scaffolding live in a single body to keep the lease/handoff sequence locally auditable.

    @Test(
        "Hand-off across multiple queued waiters is FIFO and pre-release"
    )
    func multiWaiterHandOffIsFIFOAndPreRelease() async throws {
        let boundary = OperationBoundary()
        let leaseA = await boundary.enter()
        // Per-lease cleanup defer: registered immediately
        // after each lease is captured, so a failure-path
        // exit always releases the actual current holder.
        // `exit` on a stale lease is a benign no-op.
        defer { _ = boundary.exit(leaseA) }

        // Three queued waiters behind A, registered one at a
        // time so FIFO order matches the deterministic
        // `enter()` sequence rather than scheduling jitter
        // across concurrently spawned tasks.
        let bAcquired = TestRendezvous()
        let cAcquired = TestRendezvous()
        let dAcquired = TestRendezvous()

        let bTask = Task { () -> OperationBoundary.Lease in
            let lease = await boundary.enter()
            await bAcquired.signalPaused()
            return lease
        }
        defer { bTask.cancel() }
        try await Self.waitForPendingWaiterCount(boundary, 1)

        let cTask = Task { () -> OperationBoundary.Lease in
            let lease = await boundary.enter()
            await cAcquired.signalPaused()
            return lease
        }
        defer { cTask.cancel() }
        try await Self.waitForPendingWaiterCount(boundary, 2)

        let dTask = Task { () -> OperationBoundary.Lease in
            let lease = await boundary.enter()
            await dAcquired.signalPaused()
            return lease
        }
        defer { dTask.cancel() }
        try await Self.waitForPendingWaiterCount(boundary, 3)

        // Pre-release: A holds, B/C/D queued; none has
        // signaled acquisition.
        #expect(!(await bAcquired.isPausedSignaled()))
        #expect(!(await cAcquired.isPausedSignaled()))
        #expect(!(await dAcquired.isPausedSignaled()))

        // A releases → hand off to B (FIFO head). Once
        // `awaitPaused` returns, B has executed
        // `signalPaused()` and is one statement away from
        // returning `leaseB`, so `await bTask.value` cannot
        // meaningfully race the cleanup window.
        #expect(boundary.exit(leaseA))
        try await withTestTimeout(.seconds(30)) {
            await bAcquired.awaitPaused()
        }
        let leaseB = await bTask.value
        defer { _ = boundary.exit(leaseB) }
        // State-based proof: C and D parked, not holding.
        #expect(boundary.pendingWaiterCountForTesting() == 2)
        #expect(!(await cAcquired.isPausedSignaled()))
        #expect(!(await dAcquired.isPausedSignaled()))

        // B releases → hand off to C.
        #expect(boundary.exit(leaseB))
        try await withTestTimeout(.seconds(30)) {
            await cAcquired.awaitPaused()
        }
        let leaseC = await cTask.value
        defer { _ = boundary.exit(leaseC) }
        #expect(boundary.pendingWaiterCountForTesting() == 1)
        #expect(!(await dAcquired.isPausedSignaled()))

        // C releases → hand off to D.
        #expect(boundary.exit(leaseC))
        try await withTestTimeout(.seconds(30)) {
            await dAcquired.awaitPaused()
        }
        let leaseD = await dTask.value
        defer { _ = boundary.exit(leaseD) }
        #expect(boundary.pendingWaiterCountForTesting() == 0)

        // D's matching exit closes the boundary cleanly. The
        // trailing `defer` exit on `leaseD` is a benign no-op.
        #expect(boundary.exit(leaseD))
        #expect(!boundary.exit(leaseD))
    }

    // swiftlint:enable function_body_length
}

// MARK: - Non-cancelable wait

extension OperationBoundaryTests {
    @Test(
        "Cancelled queued waiter still receives FIFO hand-off lease"
    )
    func cancelledQueuedWaiterStillReceivesFIFOHandOffLease() async throws {
        let boundary = OperationBoundary()
        let leaseA = await boundary.enter()
        // Per-lease cleanup defer: registered immediately
        // after each lease is captured, so a failure-path
        // exit always releases the actual current holder.
        // `exit` on a stale lease is a benign no-op.
        defer { _ = boundary.exit(leaseA) }

        // B queues behind A. Once we observe B is registered,
        // cancel B's task. Non-cancelable wait means B keeps
        // its place in the FIFO.
        let bAcquired = TestRendezvous()
        let bTask = Task { () -> OperationBoundary.Lease in
            let lease = await boundary.enter()
            await bAcquired.signalPaused()
            return lease
        }
        defer { bTask.cancel() }

        // C is spawned only after B is observed registered, so
        // FIFO ordering matches the deterministic `enter()`
        // sequence and is not at the mercy of scheduling
        // between two concurrently spawned tasks.
        let cAcquired = TestRendezvous()
        var cTaskHandle: Task<OperationBoundary.Lease, Never>?
        defer { cTaskHandle?.cancel() }

        try await Self.waitForPendingWaiterCount(boundary, 1)
        bTask.cancel()

        let cTask = Task { () -> OperationBoundary.Lease in
            let lease = await boundary.enter()
            await cAcquired.signalPaused()
            return lease
        }
        cTaskHandle = cTask
        try await Self.waitForPendingWaiterCount(boundary, 2)

        // A releases — B (cancelled) must still be the next
        // holder; C must not jump the queue. Once
        // `awaitPaused` returns, B has executed
        // `signalPaused()` and is one statement away from
        // returning `leaseB`, so `await bTask.value` cannot
        // meaningfully race the cleanup window.
        #expect(boundary.exit(leaseA))
        try await withTestTimeout(.seconds(30)) {
            await bAcquired.awaitPaused()
        }
        let leaseB = await bTask.value
        defer { _ = boundary.exit(leaseB) }
        #expect(!(await cAcquired.isPausedSignaled()))

        // B releases → C becomes the holder.
        #expect(boundary.exit(leaseB))
        try await withTestTimeout(.seconds(30)) {
            await cAcquired.awaitPaused()
        }
        let leaseC = await cTask.value
        defer { _ = boundary.exit(leaseC) }

        // C cleanly closes the boundary. The trailing `defer`
        // exit on `leaseC` is then a benign no-op.
        #expect(boundary.exit(leaseC))
    }
}
