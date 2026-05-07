import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Destructive-removal coverage for `FileLogStore.removeExportedLogs()`.
///
/// Pins the locked contract: `.noExportedRemovalBoundary`
/// precondition (no prior successful export, or a failed
/// export that did not capture a boundary), exported-prefix
/// deletion with byte-for-byte suffix preservation, fully
/// exported `.never` active-segment reset, fully exported
/// `.bySize` rotated-segment unlink with active-segment
/// reset, and rotated-segment compaction that preserves a
/// post-boundary suffix.
@Suite("FileLogStore destructive removal")
struct FileLogStoreRemoveTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeStore(
        directory: URL,
        rotation: RotationPolicy
    ) -> FileLogStore {
        FileLogStore(configuration: .init(directory: directory, rotation: rotation))
    }

    private static func makeUniqueDestination() throws -> (destination: URL, parent: URL) {
        let parent = uniqueDirectory()
        try makeDirectory(parent)
        return (parent.appendingPathComponent("export.ndjson"), parent)
    }

    private static func appendCanonicalLine(
        store: FileLogStore, sequence: UInt64
    ) async throws -> Data {
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: sequence, payload: Data([0x01])
        )
        try await store.append(envelope)
        return try CanonicalEnvelopeLineEncoder().encode(envelope)
    }
}

// MARK: - Boundary precondition

extension FileLogStoreRemoveTests {
    @Test(
        "Failed export does not capture a removal boundary",
        .tags(.lgp8, .lgp9)
    )
    func failedExportDoesNotCaptureBoundary() async throws {
        struct SentinelError: Error {}

        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLine(store: store, sequence: 1)
        try await store.flush()

        // Force the export to fail just before its atomic
        // commit; boundary capture must run only on the success
        // path.
        await store._setOnAfterWritingTemporaryBytesForTesting {
            throw SentinelError()
        }

        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        do {
            try await store.exportLogs(to: exportURL)
            Issue.record("expected exportLogs(to:) to throw on forced failure")
        } catch {
            // Forced export failure — exact projection is owned by export tests.
            _ = error
        }
        await store._setOnAfterWritingTemporaryBytesForTesting(nil)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .noExportedRemovalBoundary after failed export")
        } catch {
            switch error {
            case .noExportedRemovalBoundary:
                break
            default:
                Issue.record("expected .noExportedRemovalBoundary, got \(error)")
            }
        }
    }

    @Test(
        "removeExportedLogs without prior export is rejected with .noExportedRemovalBoundary",
        .tags(.lgp9)
    )
    func removeBeforeAnyExportRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .noExportedRemovalBoundary")
        } catch {
            switch error {
            case .noExportedRemovalBoundary:
                break
            default:
                Issue.record("expected .noExportedRemovalBoundary, got \(error)")
            }
        }

        // No filesystem mutation has been performed by the rejected
        // call; the store directory remains empty (no segment was
        // created since `append` was never invoked).
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
        #expect(entries.isEmpty)
    }
}

// MARK: - Segment mechanics

extension FileLogStoreRemoveTests {
    @Test(
        "Fully exported `.never` segment is reset and append continues after the removal boundary",
        .tags(.lgp9, .lgp27)
    )
    func fullyExportedNeverResetsActiveSegment() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        let line1 = try await Self.appendCanonicalLine(store: store, sequence: 1)
        try await store.flush()

        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // No post-export append. The removal boundary covers the
        // active segment's full recoverable prefix. Active
        // `.never` segment must be reset, not unlinked, so
        // subsequent appends continue after the preserved
        // removal boundary.
        try await store.removeExportedLogs()

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let afterRemove = try Data(contentsOf: segmentURL)
        #expect(afterRemove.isEmpty)
        #expect(!line1.isEmpty)

        // Subsequent append must be accepted byte-for-byte and
        // continue after the preserved removal boundary.
        let line2 = try await Self.appendCanonicalLine(store: store, sequence: 2)
        try await store.flush()
        let final = try Data(contentsOf: segmentURL)
        #expect(final == line2)
    }

    @Test(
        "`.bySize` rotated segment with post-boundary suffix is compacted byte-for-byte",
        .tags(.lgp6, .lgp9, .lgp27, .lgp39)
    )
    func bySizeRotatedSegmentCompactedPreservesSuffix() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = Self.makeStore(directory: directory, rotation: policy)

        // 3 rotated segments; log.000003 is the active writer.
        for sequence in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
        }
        try await store.flush()

        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Out-of-band: append post-boundary bytes to the
        // first rotated segment while preserving file identity.
        // File identity stays the same, so identity validation
        // passes and the compaction path triggers.
        let seg1URL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let suffixBytes = Data("POST-BOUNDARY-SUFFIX-PAYLOAD\n".utf8)
        let oobHandle = try FileHandle(forWritingTo: seg1URL)
        try oobHandle.seekToEnd()
        try oobHandle.write(contentsOf: suffixBytes)
        try oobHandle.close()

        try await store.removeExportedLogs()

        // The compacted segment must contain exactly the
        // post-boundary suffix.
        // The exported prefix is gone; the post-boundary bytes
        // survived byte-for-byte.
        #expect(FileManager.default.fileExists(atPath: seg1URL.path))
        let seg1Bytes = try Data(contentsOf: seg1URL)
        #expect(seg1Bytes == suffixBytes)
    }

    @Test(
        "Fully exported `.bySize` rotated segments are unlinked or reset",
        .tags(.lgp6, .lgp9, .lgp39)
    )
    func bySizeFullyExportedSegmentsUnlinkedOrReset() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = Self.makeStore(directory: directory, rotation: policy)

        // This rotation fixture produces one accepted line per
        // rotated segment. Three appends yield log.000001,
        // log.000002, log.000003 with log.000003 the active
        // writer.
        for sequence in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
        }
        try await store.flush()

        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        try await store.removeExportedLogs()

        let seg1 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let seg2 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )
        let seg3 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 3
        )
        // log.000001 and log.000002 were rotated and not active;
        // remove must unlink them.
        #expect(!FileManager.default.fileExists(atPath: seg1.path))
        #expect(!FileManager.default.fileExists(atPath: seg2.path))
        // log.000003 was the active writer; remove must reset it
        // to 0 so the writer handle stays usable.
        #expect(FileManager.default.fileExists(atPath: seg3.path))
        let activeBytes = try Data(contentsOf: seg3)
        #expect(activeBytes.isEmpty)
    }
}

// MARK: - Regression guard for inverted-boundary direction

extension FileLogStoreRemoveTests {
    @Test(
        "removeExportedLogs drains the pending-close queue before processing the removal boundary",
        .tags(.lgp9)
    )
    func removeDrainsPendingCloseHandlesBeforeProcessingBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        // Append → flush → export captures a removal boundary
        // referencing the active segment.
        _ = try await Self.appendCanonicalLine(store: store, sequence: 1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Plant a real, closable handle directly into the
        // pending-close queue. Removal must drain this on entry,
        // matching the discipline already exercised by `append`,
        // `flush`, and `exportLogs(to:)`.
        let pendingURL = directory.appendingPathComponent("pending.bin")
        try Data().write(to: pendingURL)
        let pendingHandle = try FileHandle(forReadingFrom: pendingURL)
        try await store._injectPendingCloseHandleForTesting(pendingHandle)
        let beforeCount = await store._pendingCloseHandleCountForTesting
        #expect(beforeCount == 1)

        try await store.removeExportedLogs()

        let afterCount = await store._pendingCloseHandleCountForTesting
        #expect(afterCount == 0)
    }

    @Test(
        "Compaction preserves the boundary segment's permission bits across atomic replacement",
        .tags(.lgp9, .lgp27)
    )
    func compactionPreservesSegmentPermissionBits() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        // Append → flush → export captures the boundary at the
        // active segment's full recoverable prefix.
        _ = try await Self.appendCanonicalLine(store: store, sequence: 1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Out-of-band: restrict the segment to `0o640` so the
        // compaction temp carrying default `0o666` would change
        // the on-disk permission bits after `renameat` if
        // permission-bit preservation were missing.
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let restrictedPermissions: mode_t = 0o640
        let chmodResult = segmentURL.path.withCString { cPath in
            Darwin.chmod(cPath, restrictedPermissions)
        }
        try #require(chmodResult == 0)

        // Append a post-boundary line so destructive mutation is
        // a compaction (atomic `renameat` replaces the segment).
        let line2 = try await Self.appendCanonicalLine(
            store: store, sequence: 2
        )
        try await store.flush()

        try await store.removeExportedLogs()

        // Compacted segment's bytes are the post-boundary suffix.
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2)

        // Compacted segment's permission bits match the
        // pre-compaction boundary segment, not the active umask
        // at compaction time.
        var statBuf = stat()
        let lstatResult = segmentURL.path.withCString { cPath in
            Darwin.lstat(cPath, &statBuf)
        }
        try #require(lstatResult == 0)
        let onDiskPermissions = mode_t(statBuf.st_mode & 0o777)
        #expect(onDiskPermissions == restrictedPermissions)
    }

    @Test(
        "removeExportedLogs deletes the exported prefix and preserves post-boundary accepted bytes",
        .tags(.lgp9, .lgp27)
    )
    func prefixRemovedSuffixPreserved() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        // Append envelope 1 — this is the exported prefix that
        // `removeExportedLogs()` must delete.
        let line1 = try await Self.appendCanonicalLine(
            store: store, sequence: 1
        )
        try await store.flush()

        // Capture the export boundary at exportedPrefixEnd = line1.count.
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Append envelope 2 — accepted *after* export commit. This
        // is the post-boundary suffix that must survive
        // `removeExportedLogs()` byte-for-byte.
        let line2 = try await Self.appendCanonicalLine(
            store: store, sequence: 2
        )
        try await store.flush()

        // Sanity-check the on-disk state before removal.
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let beforeRemove = try Data(contentsOf: segmentURL)
        #expect(beforeRemove == line1 + line2)

        // Removal must delete the exported prefix and leave the
        // post-boundary suffix intact.
        try await store.removeExportedLogs()

        let afterRemove = try Data(contentsOf: segmentURL)
        #expect(afterRemove == line2)

        // A subsequent byte-stable export must observe only the
        // post-boundary bytes, confirming the segment was
        // compacted (not truncated to `exportedPrefixEnd`, which
        // would have left only `line1`).
        let (reExportURL, reExportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(reExportParent) }
        try await store.exportLogs(to: reExportURL)
        let reExportBytes = try Data(contentsOf: reExportURL)
        #expect(reExportBytes == line2)
    }
}
