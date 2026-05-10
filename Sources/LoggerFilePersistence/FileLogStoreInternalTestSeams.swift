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

    /// TEST-ONLY: installs a seam before writable segment open.
    /// Thrown errors project to `.openWritableSegment`.
    internal func _setOnBeforeOpenWritableSegmentForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeOpenWritableSegmentForTesting = hook
    }

    /// TEST-ONLY: installs a seam before writer-root open.
    /// Thrown errors project to `.openWritableSegment`.
    internal func _setOnBeforeWriterRootOpenForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeWriterRootOpenForTesting = hook
    }

    /// TEST-ONLY: installs a seam before export temp fsync.
    /// Thrown errors project to `.writeTemporaryDestinationBytes`.
    internal func _setOnAfterWritingTemporaryBytesForTesting(
        _ hook: (@Sendable () async throws -> Void)?
    ) {
        onAfterWritingTemporaryBytesForTesting = hook
    }

    /// TEST-ONLY: installs a seam before export commit.
    /// Thrown errors project to `.commitDestination`.
    internal func _setOnBeforeCommitForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeCommitForTesting = hook
    }

    /// TEST-ONLY: installs a seam after admitted append bytes reach storage.
    internal func _setOnAfterAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onAfterAppendForTesting = hook
    }

    /// TEST-ONLY: installs a seam after append acquires the operation boundary.
    internal func _setOnBeforeAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onBeforeAppendForTesting = hook
    }

    /// TEST-ONLY: installs a seam before export temp close.
    /// Thrown errors project to `.closeTemporaryDestination`.
    internal func _setOnCloseTemporaryDestinationForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onCloseTemporaryDestinationForTesting = hook
    }

    /// TEST-ONLY: installs a seam before each per-entry removal mutation.
    /// Thrown errors project to `.validateBoundary`.
    internal func _setOnBeforeProcessRemovalEntryForTesting(
        _ hook: (@Sendable (URL) async throws -> Void)?
    ) {
        onBeforeProcessRemovalEntryForTesting = hook
    }

    /// TEST-ONLY: installs a seam before active-writer reopen after removal mutation.
    internal func _setOnBeforeReopenActiveSegmentForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeReopenActiveSegmentForTesting = hook
    }

    /// TEST-ONLY: installs a seam before compaction opens a segment for reading.
    /// Thrown errors project to `.openSegment`.
    internal func _setOnBeforeOpenCompactionReadForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeOpenCompactionReadForTesting = hook
    }

    /// TEST-ONLY: installs a seam before compaction's pre-replace boundary revalidation.
    /// Thrown errors project to `.validateBoundary`.
    internal func _setOnBeforePreReplaceRevalidateForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforePreReplaceRevalidateForTesting = hook
    }

    /// TEST-ONLY: installs a rotated-topology classification override.
    internal func _setRotatedTopologyOverrideForTesting(
        _ hook: (@Sendable () -> InternalReadError?)?
    ) {
        rotatedTopologyOverrideForTesting = hook
    }

    /// TEST-ONLY: installs a seam before each retention segment deletion.
    /// Thrown errors project to `.enforceRetention`.
    internal func _setOnBeforeRetentionUnlinkForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeRetentionUnlinkForTesting = hook
    }

    /// TEST-ONLY: installs a seam between successful leaf `mkdir(2)`
    /// and the umask-independent permission preservation step.
    /// Thrown errors project to `.createDirectory`.
    internal func _setOnBeforeDirectoryChmodForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        onBeforeDirectoryChmodForTesting = hook
    }

    // swiftlint:enable identifier_name
}
