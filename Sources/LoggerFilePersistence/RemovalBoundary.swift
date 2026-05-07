import Darwin
import Foundation

/// In-memory removal boundary captured by a successful
/// byte-stable export. The boundary authorizes
/// `removeExportedLogs()` to delete the exported prefix while
/// preserving accepted bytes admitted after the successful export
/// destination commit.
///
/// The boundary is implicit and lives only for the actor's
/// in-process lifetime. A process restart clears it; a later
/// `removeExportedLogs()` then fails with
/// `.noExportedRemovalBoundary` and the caller must export
/// again.
internal struct RemovalBoundary: Sendable, Equatable {
    let entries: [RemovalBoundaryEntry]
}

/// Per-segment record of an exported prefix. The removal
/// operation may unlink, compact, or reset the segment in
/// accordance with `exportedPrefixEnd`, and must not modify
/// any byte at or after that offset.
internal struct RemovalBoundaryEntry: Sendable, Equatable {
    /// Segment URL at the time of export commit.
    let url: URL
    /// Numeric segment sequence parsed from the rotated
    /// filename, or `nil` for the unrotated `.never` segment.
    let numericSequence: UInt64?
    /// Segment file identity captured at export time. Used by
    /// `removeExportedLogs()` to fail closed when the segment
    /// has been replaced out-of-band between export commit
    /// and removal.
    let fileIdentity: FileIdentity
    /// Byte offset immediately after the last accepted byte
    /// emitted from this segment. Bytes before this offset
    /// are eligible for removal; bytes at or after this
    /// offset are outside the removal boundary and must be
    /// preserved byte-for-byte.
    let exportedPrefixEnd: UInt64
}

/// Stable segment file identity captured during export-boundary
/// discovery and revalidated before destructive removal.
/// Matching identity at removal time confirms the segment is the
/// same segment file observed during export-boundary capture.
internal struct FileIdentity: Sendable, Equatable {
    // periphery:ignore - Periphery does not trace synthesized Equatable reads.
    let device: Darwin.dev_t
    // periphery:ignore - Periphery does not trace synthesized Equatable reads.
    let inode: Darwin.ino_t
}
