import Foundation

// TEST-ONLY seams used through @testable import.
// Do not expose as public API or SPI.

// MARK: - Test seam failures

internal enum TestSeamFailure: Error, Sendable {
    case noActiveSegment
    case handleAlreadyPendingClose
}

// MARK: - Failure-injection seams

extension FileLogStore {
    // swiftlint:disable identifier_name

    /// TEST-ONLY: installs a test seam that fires immediately before each
    /// `openSegmentForWriting` call (initial open and rotation) once
    /// the held writer root is in hand. A throw from the test seam is
    /// projected onto `.openWritableSegment`.
    internal func _setOnBeforeOpenWritableSegmentForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeOpenWritableSegmentForTesting = hook
    }

    /// TEST-ONLY: installs a test seam that fires between the post-create
    /// root `lstat` snapshot and the `SegmentRoot.open` call. A
    /// throw from the test seam is projected onto `.openWritableSegment`.
    internal func _setOnBeforeWriterRootOpenForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeWriterRootOpenForTesting = hook
    }

    /// TEST-ONLY: installs a seam before export temp fsync.
    /// Throws project to `.writeTemporaryDestinationBytes`.
    internal func _setOnAfterWritingTemporaryBytesForTesting(
        _ hook: (@Sendable () async throws -> Void)?
    ) {
        onAfterWritingTemporaryBytesForTesting = hook
    }

    /// TEST-ONLY: installs a test seam fired inside the export critical
    /// section after the temp file is closed and immediately
    /// before the atomic commit, used to plant a destination
    /// entry between final pre-check and `renameatx_np`. A throw
    /// projects to `.operationFailed(.commitDestination)`.
    internal func _setOnBeforeCommitForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeCommitForTesting = hook
    }

    /// TEST-ONLY: installs a test seam fired at the end of `append`
    /// after admitted bytes reach the active segment. Used to
    /// observe append completion ordering against export.
    internal func _setOnAfterAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onAfterAppendForTesting = hook
    }

    /// TEST-ONLY: installs a test seam fired at the first instruction
    /// of `append`, immediately after the operation boundary is
    /// acquired. Pairs with `_setOnAfterAppendForTesting` to record
    /// the append operation interval for single-flight proofs.
    internal func _setOnBeforeAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onBeforeAppendForTesting = hook
    }

    /// TEST-ONLY: installs a test seam that simulates a `close(2)`
    /// failure on the export temporary file. A throw projects to
    /// `.operationFailed(.closeTemporaryDestination)`; the
    /// descriptor is best-effort closed for test cleanup.
    internal func _setOnCloseTemporaryDestinationForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onCloseTemporaryDestinationForTesting = hook
    }

    /// TEST-ONLY: installs an async rendezvous seam before each
    /// per-entry removal mutation. Throws project to
    /// `.operationFailed(.validateBoundary)`.
    internal func _setOnBeforeProcessRemovalEntryForTesting(
        _ hook: (@Sendable (URL) async throws -> Void)?
    ) {
        onBeforeProcessRemovalEntryForTesting = hook
    }

    /// TEST-ONLY: installs a test seam fired after a destructive
    /// segment mutation completes but before the active-writer
    /// reopen runs. Used to assert the boundary tail advances
    /// past the entry once destruction has occurred.
    internal func _setOnBeforeReopenActiveSegmentForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeReopenActiveSegmentForTesting = hook
    }

    /// TEST-ONLY: installs a test seam fired immediately before
    /// the compaction read descriptor is opened, after per-entry
    /// revalidation has succeeded. A throw projects to
    /// `.operationFailed(.openSegment)`. Used to deterministically
    /// race a regular-file swap or a truncate-below-boundary
    /// against the compaction-time revalidation.
    internal func _setOnBeforeOpenCompactionReadForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeOpenCompactionReadForTesting = hook
    }

    /// TEST-ONLY: classification seam for stale-boundary
    /// rotated-topology validation. Returning a non-nil
    /// `InternalReadError` bypasses on-disk enumeration and
    /// injects a synthetic failure into the classification
    /// pipeline.
    internal func _setRotatedTopologyOverrideForTesting(
        _ hook: (@Sendable () -> InternalReadError?)?
    ) {
        rotatedTopologyOverrideForTesting = hook
    }

    // swiftlint:enable identifier_name
}
