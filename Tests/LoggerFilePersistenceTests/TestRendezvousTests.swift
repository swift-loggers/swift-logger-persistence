import Foundation
import Testing

/// Cancellation and timeout coverage for `TestRendezvous`.
@Suite("TestRendezvous cancellation contract")
struct TestRendezvousTests {
    private static let waiterPollInterval: Duration = .milliseconds(10)

    /// Bounded poll for a paused-side waiter count condition.
    private static func awaitPausedCount(
        rendezvous: TestRendezvous,
        equals target: Int
    ) async throws {
        try await withTestTimeout(.seconds(5)) {
            while await rendezvous.pendingPausedWaiterCountForTesting() != target {
                try await Task.sleep(for: waiterPollInterval)
            }
        }
    }

    /// Bounded poll for a release-side waiter count condition.
    private static func awaitReleaseCount(
        rendezvous: TestRendezvous,
        equals target: Int
    ) async throws {
        try await withTestTimeout(.seconds(5)) {
            while await rendezvous.pendingReleaseWaiterCountForTesting() != target {
                try await Task.sleep(for: waiterPollInterval)
            }
        }
    }
}

// MARK: - withTestTimeout does not join non-cooperative inner

extension TestRendezvousTests {
    @Test(
        "withTestTimeout fires within bound on a non-cancellation-cooperative inner"
    )
    func timeoutDoesNotJoinInnerTask() async {
        let suspension = ReleasableSuspension()
        // Always release the non-cooperative inner task.
        defer { suspension.release() }

        do {
            try await withTestTimeout(
                .milliseconds(50),
                description: "non-cooperative inner"
            ) {
                // Ignores cancellation; released by cleanup after timeout.
                await suspension.wait()
            }
            Issue.record("expected TestTimeoutError")
        } catch is TestTimeoutError {
            suspension.release()
        } catch {
            Issue.record("expected TestTimeoutError, got \(error)")
        }
    }
}

// MARK: - Test helpers

/// Non-cooperative suspension that ignores `Task.cancel()` but
/// can be released explicitly. Lets a test exercise the
/// "timeout does not join inner" path without leaving a
/// permanently suspended task behind.
private final class ReleasableSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: UnsafeContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withUnsafeContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

// MARK: - TestTimeoutOutcome generic-safe completion storage

extension TestRendezvousTests {
    @Test(
        "TestTimeoutOutcome preserves a pre-completed optional-nil success"
    )
    func timeoutOutcomePreservesOptionalNilSuccess() async throws {
        // Pins the contract that an `R == Optional<T>` success of
        // `nil` is unambiguously stored and resumed, with no
        // collision against the "no completion yet" state.
        let outcome = TestTimeoutOutcome<Int?>()
        await outcome.completeSuccess(nil)
        let value = try await withTestTimeout(.seconds(5)) {
            try await outcome.wait()
        }
        #expect(value == nil)
    }
}

// MARK: - Cancellation cleans up the rendezvous waiter table

extension TestRendezvousTests {
    @Test(
        "Cancelled awaitPaused() waiter does not remain registered"
    )
    func cancelledPausedWaiterDoesNotRemainRegistered() async throws {
        let rendezvous = TestRendezvous()
        let task = Task {
            await rendezvous.awaitPaused()
        }
        // Cancel as early as possible to exercise the
        // cancel-vs-registration race window. Either path is
        // valid: cancellation prevented registration, or the
        // cancel handler removed an already-registered waiter.
        task.cancel()
        try await Self.awaitPausedCount(rendezvous: rendezvous, equals: 0)
        try await withTestTimeout(.seconds(5)) {
            await task.value
        }
    }

    @Test(
        "Cancelled awaitRelease() waiter does not remain registered"
    )
    func cancelledReleaseWaiterDoesNotRemainRegistered() async throws {
        let rendezvous = TestRendezvous()
        let task = Task {
            await rendezvous.awaitRelease()
        }
        task.cancel()
        try await Self.awaitReleaseCount(rendezvous: rendezvous, equals: 0)
        try await withTestTimeout(.seconds(5)) {
            await task.value
        }
    }

    @Test(
        "Cancelled registered awaitPaused waiter is removed"
    )
    func cancelledRegisteredPausedWaiterIsRemoved() async throws {
        let rendezvous = TestRendezvous()
        let task = Task {
            await rendezvous.awaitPaused()
        }
        // Cleanup-on-failure: a timeout in any intermediate
        // bounded wait must not leave a suspended waiter task
        // outliving the test.
        defer { task.cancel() }
        // Wait until the waiter is deterministically
        // registered, then cancel — exercises the
        // post-registration cancel cleanup path.
        try await Self.awaitPausedCount(rendezvous: rendezvous, equals: 1)
        task.cancel()
        try await Self.awaitPausedCount(rendezvous: rendezvous, equals: 0)
        try await withTestTimeout(.seconds(5)) {
            await task.value
        }
    }

    @Test(
        "Cancelled registered awaitRelease waiter is removed"
    )
    func cancelledRegisteredReleaseWaiterIsRemoved() async throws {
        let rendezvous = TestRendezvous()
        let task = Task {
            await rendezvous.awaitRelease()
        }
        defer { task.cancel() }
        try await Self.awaitReleaseCount(rendezvous: rendezvous, equals: 1)
        task.cancel()
        try await Self.awaitReleaseCount(rendezvous: rendezvous, equals: 0)
        try await withTestTimeout(.seconds(5)) {
            await task.value
        }
    }
}

// MARK: - Multi-waiter broadcast

extension TestRendezvousTests {
    @Test(
        "signalPaused resumes every registered awaiter"
    )
    func multiWaiterSignalPausedResumesAll() async throws {
        let rendezvous = TestRendezvous()
        let aDone = TestRendezvous()
        let bDone = TestRendezvous()

        let waiterA = Task {
            await rendezvous.awaitPaused()
            await aDone.signalPaused()
        }
        let waiterB = Task {
            await rendezvous.awaitPaused()
            await bDone.signalPaused()
        }
        // Cleanup-on-failure: a timeout in any intermediate
        // bounded wait must not leave suspended waiter tasks
        // outliving the test.
        defer {
            waiterA.cancel()
            waiterB.cancel()
        }

        // Deterministic broadcast proof: both waiters must be
        // registered before the signal fires. Otherwise an
        // early signaler would let registration paths short-
        // circuit through `pausedSignaled == true` and the
        // test would not actually exercise broadcast.
        try await Self.awaitPausedCount(rendezvous: rendezvous, equals: 2)
        await rendezvous.signalPaused()

        try await withTestTimeout(.seconds(5)) {
            await aDone.awaitPaused()
        }
        try await withTestTimeout(.seconds(5)) {
            await bDone.awaitPaused()
        }
        try await withTestTimeout(.seconds(5)) {
            await waiterA.value
        }
        try await withTestTimeout(.seconds(5)) {
            await waiterB.value
        }

        let count = await rendezvous.pendingPausedWaiterCountForTesting()
        #expect(count == 0)
    }

    @Test(
        "signalRelease resumes every registered awaiter"
    )
    func multiWaiterSignalReleaseResumesAll() async throws {
        let rendezvous = TestRendezvous()
        let aDone = TestRendezvous()
        let bDone = TestRendezvous()

        let waiterA = Task {
            await rendezvous.awaitRelease()
            await aDone.signalPaused()
        }
        let waiterB = Task {
            await rendezvous.awaitRelease()
            await bDone.signalPaused()
        }
        defer {
            waiterA.cancel()
            waiterB.cancel()
        }

        try await Self.awaitReleaseCount(rendezvous: rendezvous, equals: 2)
        await rendezvous.signalRelease()

        try await withTestTimeout(.seconds(5)) {
            await aDone.awaitPaused()
        }
        try await withTestTimeout(.seconds(5)) {
            await bDone.awaitPaused()
        }
        try await withTestTimeout(.seconds(5)) {
            await waiterA.value
        }
        try await withTestTimeout(.seconds(5)) {
            await waiterB.value
        }

        let count = await rendezvous.pendingReleaseWaiterCountForTesting()
        #expect(count == 0)
    }
}
