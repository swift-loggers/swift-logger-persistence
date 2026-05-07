import Testing

/// Continuation-based pause/release rendezvous for
/// concurrency tests that pin operation-vs-operation
/// ordering. Awaiters suspend through async continuations;
/// signaling resumes every waiter registered on that side.
/// No blocking primitive runs inside an actor-isolated seam,
/// so a low-core CI executor cannot starve sibling tests
/// during a rendezvous.
///
/// Cancellation either prevents waiter registration or
/// removes an already-registered continuation, so later
/// signals do not have to clean up cancelled waiters.
///
/// Usage shape:
///
/// ```swift
/// let rendezvous = TestRendezvous()
/// await store._setOnBeforeProcessRemovalEntryForTesting { _ in
///     await rendezvous.signalPaused()
///     await rendezvous.awaitRelease()
/// }
/// let task = Task { try await store.removeExportedLogs() }
/// try await withTestTimeout(.seconds(5)) {
///     await rendezvous.awaitPaused()
/// }
/// // … pre-release proof …
/// await rendezvous.signalRelease()
/// try await task.value
/// ```
internal actor TestRendezvous {
    private var pausedSignaled = false
    private var pausedWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    private var releaseSignaled = false
    private var releaseWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    private var nextWaiterID: UInt64 = 0

    /// Awaits the pause signal. Returns immediately if the
    /// pause has already been signaled or if the calling task
    /// is cancelled. Multiple awaiters are supported; each
    /// registered continuation is resumed when the signal
    /// fires.
    func awaitPaused() async {
        if pausedSignaled { return }
        let id = mintWaiterID()
        await withTaskCancellationHandler {
            await self.suspendUntilPaused(id: id)
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPausedWaiter(id: id)
            }
        }
    }

    private func suspendUntilPaused(id: UInt64) async {
        await withCheckedContinuation { cont in
            // Closing the cancellation-vs-registration race: if
            // `Task.isCancelled` already holds at registration
            // time, resume immediately. Otherwise a cancel
            // handler that ran before this registration would
            // find no waiter to remove, the registration would
            // park the continuation, and no later cleanup would
            // arrive.
            if pausedSignaled || Task.isCancelled {
                cont.resume()
            } else {
                pausedWaiters[id] = cont
            }
        }
    }

    private func cancelPausedWaiter(id: UInt64) {
        guard let cont = pausedWaiters.removeValue(forKey: id) else { return }
        cont.resume()
    }

    /// Non-blocking observation of whether the pause signal has
    /// already fired. Lets a test assert "the task did not
    /// reach the pause point yet" without consuming the signal.
    func isPausedSignaled() -> Bool {
        pausedSignaled
    }

    /// Signals that the in-body code reached the pause point.
    /// Resumes every awaiter registered on the pause side.
    func signalPaused() {
        pausedSignaled = true
        let waiters = pausedWaiters
        pausedWaiters = [:]
        for (_, cont) in waiters {
            cont.resume()
        }
    }

    /// Awaits the release signal. Returns immediately if the
    /// release has already been signaled or if the calling task
    /// is cancelled. Multiple awaiters are supported.
    func awaitRelease() async {
        if releaseSignaled { return }
        let id = mintWaiterID()
        await withTaskCancellationHandler {
            await self.suspendUntilReleased(id: id)
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReleaseWaiter(id: id)
            }
        }
    }

    private func suspendUntilReleased(id: UInt64) async {
        await withCheckedContinuation { cont in
            // Closing the cancellation-vs-registration race: if
            // `Task.isCancelled` already holds at registration
            // time, resume immediately. Otherwise a cancel
            // handler that ran before this registration would
            // find no waiter to remove, the registration would
            // park the continuation, and no later cleanup would
            // arrive.
            if releaseSignaled || Task.isCancelled {
                cont.resume()
            } else {
                releaseWaiters[id] = cont
            }
        }
    }

    private func cancelReleaseWaiter(id: UInt64) {
        guard let cont = releaseWaiters.removeValue(forKey: id) else { return }
        cont.resume()
    }

    /// Signals that the paused body is authorized to release.
    /// Resumes every awaiter registered on the release side.
    func signalRelease() {
        releaseSignaled = true
        let waiters = releaseWaiters
        releaseWaiters = [:]
        for (_, cont) in waiters {
            cont.resume()
        }
    }

    /// TEST-ONLY: parked pause-side waiter count.
    func pendingPausedWaiterCountForTesting() -> Int {
        pausedWaiters.count
    }

    /// TEST-ONLY: parked release-side waiter count.
    func pendingReleaseWaiterCountForTesting() -> Int {
        releaseWaiters.count
    }

    private func mintWaiterID() -> UInt64 {
        nextWaiterID += 1
        return nextWaiterID
    }
}

/// Error thrown by ``withTestTimeout(_:description:operation:)``
/// when the inner operation does not complete within the
/// allotted duration.
internal struct TestTimeoutError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String = "test timeout") {
        self.description = description
    }
}

/// Bounds an outer test wait. The timeout fires at the outer
/// test boundary, throwing ``TestTimeoutError`` whether or not
/// the inner operation cooperates with cancellation.
///
/// Implementation note: the inner operation runs in an
/// unstructured `Task`. When the timeout wins the race, this
/// helper cancels the inner task and returns immediately —
/// it does **not** join the inner task on the timeout path.
/// A non-cancellation-cooperative operation therefore cannot
/// hang the test by ignoring `Task.cancel()`; the outer test
/// boundary always exits inside the configured duration.
internal func withTestTimeout<R: Sendable>(
    _ duration: Duration,
    description: String = "test timeout",
    operation: @Sendable @escaping () async throws -> R
) async throws -> R {
    let outcome = TestTimeoutOutcome<R>()

    let innerTask = Task {
        do {
            let value = try await operation()
            await outcome.completeSuccess(value)
        } catch {
            await outcome.completeFailure(error)
        }
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: duration)
        await outcome.completeFailure(TestTimeoutError(description))
    }

    defer {
        innerTask.cancel()
        timeoutTask.cancel()
    }
    return try await outcome.wait()
}

/// Failure-path cleanup for rendezvous tests.
///
/// Releases the rendezvous, cancels started tasks, and bounded-drains
/// task outcomes without masking the original test failure.
internal func releaseCancelAndDrain(
    rendezvous: TestRendezvous,
    tasks: [Task<Void, any Error>],
    context: String,
    timeout: Duration = .seconds(5)
) async {
    // Release before cancellation so paused holders can free the boundary.
    await rendezvous.signalRelease()
    for task in tasks {
        task.cancel()
    }
    for (index, task) in tasks.enumerated() {
        do {
            try await withTestTimeout(
                timeout,
                description: "\(context) cleanup task \(index)"
            ) {
                _ = try await task.value
            }
        } catch is TestTimeoutError {
            Issue.record(
                "\(context): cleanup timed out draining task \(index)"
            )
        } catch is CancellationError {
            // Expected after `task.cancel()` — tolerated silently.
        } catch {
            Issue.record(
                "\(context): cleanup error draining task \(index): \(error)"
            )
        }
    }
}

/// Single-shot completion sink for ``withTestTimeout``.
///
/// Storage is `Result<R, any Error>?` so a generic `R == Optional<T>`
/// success of `nil` is unambiguously distinguishable from "no
/// completion yet" — `R?` would conflate the two states for any
/// optional payload.
internal actor TestTimeoutOutcome<R: Sendable> {
    private var done = false
    private var pending: Result<R, any Error>?
    private var waiter: CheckedContinuation<R, Error>?

    func wait() async throws -> R {
        try await withCheckedThrowingContinuation { cont in
            if done {
                switch pending {
                case let .success(value):
                    pending = nil
                    cont.resume(returning: value)
                case let .failure(error):
                    pending = nil
                    cont.resume(throwing: error)
                case nil:
                    // Test-helper misuse: a second `wait()` after a
                    // direct-resumed completion. Surface as a throwable
                    // error so the misusing test fails deterministically.
                    cont.resume(throwing: TestTimeoutError("test timeout outcome reused"))
                }
            } else {
                waiter = cont
            }
        }
    }

    func completeSuccess(_ value: R) {
        guard !done else { return }
        done = true
        if let cont = waiter {
            waiter = nil
            cont.resume(returning: value)
        } else {
            pending = .success(value)
        }
    }

    func completeFailure(_ error: Error) {
        guard !done else { return }
        done = true
        if let cont = waiter {
            waiter = nil
            cont.resume(throwing: error)
        } else {
            pending = .failure(error)
        }
    }
}
