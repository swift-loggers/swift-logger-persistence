import Foundation

/// Public removal error surface for `FileLogStore.removeExportedLogs()`.
///
/// The full removal contract — boundary semantics, atomicity,
/// and retry behavior — is owned by the API design ("Destructive
/// removal").
public enum FileLogStoreRemoveError: Error, Sendable, Equatable {
    /// Operation-local classification for non-compatibility-classified
    /// filesystem failures during removal.
    case operationFailed(
        operation: FileLogStoreRemoveOperation,
        url: URL,
        context: FileSystemErrorContext
    )
    /// `removeExportedLogs()` was invoked without a prior
    /// successful `exportLogs(to:)` since the current in-memory
    /// removal-boundary state was established.
    /// Callers must export before removing.
    case noExportedRemovalBoundary
    /// The captured boundary references a topology that is no
    /// longer observable on disk (file identity mismatch,
    /// missing segment, or insufficient size). Removal is
    /// rejected before destructive mutation of the affected
    /// boundary entry.
    case removalBoundaryStale(
        url: URL,
        context: FileSystemErrorContext
    )
    /// Implementation invariant violation. Reports a defect in
    /// the package, not a caller error.
    case implementationInvariantViolation(violation: PersistenceInvariantError)
}

/// Observable removal-pipeline operation classification used by
/// `FileLogStoreRemoveError.operationFailed`.
public enum FileLogStoreRemoveOperation: String, Sendable, Equatable {
    /// Pre-mutation boundary re-validation against on-disk
    /// topology and per-entry file identity.
    case validateBoundary
    /// Descriptor-relative open of a segment named in the
    /// removal boundary.
    case openSegment
    /// Reading the post-boundary suffix from a segment whose
    /// boundary entry terminates mid-file.
    case readPreservedSuffix
    /// Creation of the unique compaction temporary file.
    case createCompactionTemporary
    /// Writing the preserved suffix bytes to the compaction
    /// temporary file.
    case writeCompactionTemporaryBytes
    /// Durable synchronization of the compaction temporary
    /// file before segment replacement.
    case syncCompactionTemporary
    /// Finalization of the compaction temporary file before
    /// atomic segment replacement.
    case closeCompactionTemporary
    /// Atomic commit replacing the boundary-covered segment
    /// with the compacted replacement segment.
    case replaceSegment
    /// Reopening or resetting the active writer descriptor
    /// after compaction or active-segment reset.
    case reopenActiveSegment
    /// Removal of a fully-exported rotated segment from the
    /// active segment topology.
    case unlinkSegment
}
