import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Failure-mid-removal coverage: a per-segment failure must
/// retain only the unprocessed boundary tail for retry, and a
/// subsequent successful call must complete the remainder
/// before clearing the boundary.
@Suite("FileLogStore destructive removal — failure retains remaining")
struct FileLogStoreRemoveFailureTests {
    private struct SentinelError: Error {}

    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeUniqueDestination() throws -> (destination: URL, parent: URL) {
        let parent = uniqueDirectory()
        try makeDirectory(parent)
        return (parent.appendingPathComponent("export.ndjson"), parent)
    }

    /// Sets up a `.bySize` store with three rotated segments and
    /// captures a removal boundary spanning all three. Returns
    /// the store and the export parent URL the caller is
    /// responsible for cleaning up.
    private static func setupBoundaryWithThreeRotatedSegments(
        directory: URL
    ) async throws -> (store: FileLogStore, exportParent: URL) {
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: policy)
        )
        for sequence in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
        }
        try await store.flush()
        let (exportURL, exportParent) = try makeUniqueDestination()
        try await store.exportLogs(to: exportURL)
        return (store, exportParent)
    }
}

extension FileLogStoreRemoveFailureTests {
    @Test(
        "Per-segment failure retains the unprocessed boundary tail; retry completes",
        .tags(.lgp6, .lgp9, .lgp39)
    )
    func failureRetainsRemainingBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        // Three rotated segments; log.000003 is the active
        // writer. Removal will process them in boundary order.
        let (store, exportParent) = try await Self.setupBoundaryWithThreeRotatedSegments(
            directory: directory
        )
        defer { FileLogStoreTestSupport.remove(exportParent) }

        // Configure a one-shot test seam that fails on the
        // second entry (log.000002) only.
        let failTarget = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )
        await store._setOnBeforeProcessRemovalEntryForTesting { url in
            if url == failTarget {
                throw SentinelError()
            }
        }

        // First call: processes log.000001 successfully, fails
        // on log.000002, retains the unprocessed tail
        // (log.000002 + log.000003) for retry.
        do {
            try await store.removeExportedLogs()
            Issue.record("expected operationFailed during forced failure")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .validateBoundary)
                #expect(url == failTarget)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }

        let seg1 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let seg2 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )
        let seg3 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 3
        )
        // log.000001 was processed successfully (unlinked).
        #expect(!FileManager.default.fileExists(atPath: seg1.path))
        // log.000002 and log.000003 untouched: failure happened
        // before any destructive removal step for log.000002.
        #expect(FileManager.default.fileExists(atPath: seg2.path))
        #expect(FileManager.default.fileExists(atPath: seg3.path))

        // Clear the seam and retry — the retained tail must
        // complete and the boundary must clear.
        await store._setOnBeforeProcessRemovalEntryForTesting(nil)
        try await store.removeExportedLogs()

        #expect(!FileManager.default.fileExists(atPath: seg2.path))
        // log.000003 was active at export time; successful removal
        // leaves no accepted bytes before the removal boundary.
        #expect(FileManager.default.fileExists(atPath: seg3.path))
        #expect(try Data(contentsOf: seg3).isEmpty)

        try await Self.assertBoundaryClearedAfterSuccess(store: store)
    }

    /// Boundary tail must advance past entries whose
    /// destructive mutation already completed, even when the
    /// active-writer reopen step subsequently fails. Otherwise
    /// retry would re-validate an already-mutated entry against
    /// stale boundary metadata and fail closed permanently.
    @Test(
        "Active-writer reopen failure advances boundary past the mutated entry",
        .tags(.lgp9, .lgp27)
    )
    func reopenFailureAfterMutationAdvancesBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        // Append → flush → export captures a `.never` boundary
        // referencing the active segment.
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Append a post-boundary line so destructive mutation is
        // a compaction (not a fully-exported reset path).
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        await store._setOnBeforeReopenActiveSegmentForTesting { _ in
            throw SentinelError()
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .operationFailed(.reopenActiveSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .reopenActiveSegment)
            default:
                Issue.record("expected reopenActiveSegment failure, got \(error)")
            }
        }

        // Compaction already replaced the segment on disk;
        // post-boundary suffix is preserved byte-for-byte.
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2)

        // Boundary tail advanced past the mutated entry: a
        // retry without the seam must observe the
        // no-remaining-boundary success path, not re-validate
        // stale identity.
        await store._setOnBeforeReopenActiveSegmentForTesting(nil)
        try await store.removeExportedLogs()

        // After full success, boundary is cleared.
        try await Self.assertBoundaryClearedAfterSuccess(store: store)
    }

    /// Failure after the destructive active-segment reset step
    /// and before the writer-offset-reset step must advance the
    /// boundary tail past the entry. Otherwise retry would
    /// re-validate against stale boundary metadata and
    /// fail closed permanently.
    @Test(
        "Writer-offset reset failure after active-segment reset advances boundary past the entry",
        .tags(.lgp9, .lgp27)
    )
    func writerOffsetResetFailureAfterActiveSegmentResetAdvancesBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        // Append → flush → export captures the boundary at
        // `exportedPrefixEnd == fileSize`. No post-export
        // append, so the destructive path is active-segment reset
        // (not compaction).
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        await store._setOnBeforeReopenActiveSegmentForTesting { _ in
            throw SentinelError()
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected reopenActiveSegment failure after active-segment reset")
        } catch {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .reopenActiveSegment)
            default:
                Issue.record("expected reopenActiveSegment failure, got \(error)")
            }
        }

        // Active-segment reset already completed on disk.
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk.isEmpty)

        // Boundary advanced past the destructive entry: a
        // retry without the seam must observe the
        // no-remaining-boundary success path, not re-validate
        // against pre-reset boundary metadata.
        await store._setOnBeforeReopenActiveSegmentForTesting(nil)
        try await store.removeExportedLogs()
        try await Self.assertBoundaryClearedAfterSuccess(store: store)
    }

    /// Append after a failed active-segment reset path must land in a
    /// fresh segment (not in the stale-offset pre-reset
    /// handle), so the on-disk byte sequence is canonical and
    /// contains no sparse gap between the active-segment reset
    /// and the next admitted line.
    @Test(
        "Append after failed active-segment reset path produces canonical bytes",
        .tags(.lgp9, .lgp24, .lgp25, .lgp27)
    )
    func appendAfterFailedResetProducesCanonicalBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        // Append → flush → export captures the boundary at the
        // active segment's full recoverable prefix.
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Force the post-mutation step to fail after the
        // destructive truncate has already completed on disk.
        await store._setOnBeforeReopenActiveSegmentForTesting { _ in
            throw SentinelError()
        }
        do {
            try await store.removeExportedLogs()
            Issue.record("expected post-mutation failure")
        } catch {
            switch error {
            case .operationFailed:
                break
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
        await store._setOnBeforeReopenActiveSegmentForTesting(nil)

        // Subsequent append must produce a canonical on-disk
        // sequence — exactly the new accepted line's bytes,
        // with no hole or stale prefix carried over from the
        // pre-reset writer offset.
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2)
    }

    /// Append after a failed reopen-after-compaction must land
    /// in the on-disk compacted segment at the boundary path,
    /// not in the detached pre-compaction inode that the
    /// pre-reopen writer handle still references. Catches
    /// regressions where the writer is not invalidated after
    /// the reopen step fails.
    @Test(
        "Append after failed reopen-after-compaction produces canonical bytes",
        .tags(.lgp9, .lgp24, .lgp25, .lgp27)
    )
    func appendAfterFailedReopenAfterCompactionProducesCanonicalBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        // Append → flush → export captures the boundary at the
        // active segment's full recoverable prefix.
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Append a post-boundary line so destructive mutation is
        // a compaction (atomic `renameat` replaces the active
        // segment) — not a fully-exported reset.
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        // Force the reopen step to fail after the destructive
        // atomic replacement has already completed on disk.
        await store._setOnBeforeReopenActiveSegmentForTesting { _ in
            throw SentinelError()
        }
        do {
            try await store.removeExportedLogs()
            Issue.record("expected .operationFailed(.reopenActiveSegment) after compaction")
        } catch {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .reopenActiveSegment)
            default:
                Issue.record("expected reopenActiveSegment failure, got \(error)")
            }
        }
        await store._setOnBeforeReopenActiveSegmentForTesting(nil)

        // Subsequent append must land in the on-disk compacted
        // segment at the boundary path. If the active writer
        // were not invalidated after the failed reopen, the
        // stale handle would reference the detached pre-
        // compaction inode and the on-disk file would still
        // contain only `line2` after the new append.
        let envelope3 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 3, payload: Data([0x03])
        )
        try await store.append(envelope3)
        try await store.flush()
        let line3 = try CanonicalEnvelopeLineEncoder().encode(envelope3)

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2 + line3)
    }

    /// Confirms successful removal cleared the in-memory
    /// removal boundary by exercising the no-boundary path on
    /// a follow-up call.
    private static func assertBoundaryClearedAfterSuccess(
        store: FileLogStore
    ) async throws {
        do {
            try await store.removeExportedLogs()
            Issue.record("expected .noExportedRemovalBoundary after full success")
        } catch {
            switch error {
            case .noExportedRemovalBoundary:
                break
            default:
                Issue.record("expected .noExportedRemovalBoundary, got \(error)")
            }
        }
    }
}
