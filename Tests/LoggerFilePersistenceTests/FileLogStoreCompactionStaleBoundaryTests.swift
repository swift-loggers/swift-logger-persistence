import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Compaction-time stale-boundary coverage for
/// `FileLogStore.removeExportedLogs()`. Exercises the narrow
/// window between per-entry revalidation and compaction-read
/// open where a vanish, symlink swap, identity swap, or
/// truncate-below-boundary must fail closed with
/// `.removalBoundaryStale` and leave no compaction temp behind.
@Suite("FileLogStore destructive removal — compaction-time stale boundary")
struct FileLogStoreCompactionStaleBoundaryTests {
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

    private static func setupRotatedCompactionFixture(
        directory: URL
    ) async throws -> (store: FileLogStore, seg1URL: URL) {
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = makeStore(directory: directory, rotation: policy)
        for sequence in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
        }
        try await store.flush()

        let (exportURL, exportParent) = try makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Append post-boundary bytes to seg1 while preserving file
        // identity, so the per-entry-revalidation step succeeds and
        // the destructive path enters `compactSegment`.
        let seg1URL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let oob = try FileHandle(forWritingTo: seg1URL)
        try oob.seekToEnd()
        try oob.write(contentsOf: Data("POST-BOUNDARY-SUFFIX\n".utf8))
        try oob.close()

        return (store, seg1URL)
    }
}

extension FileLogStoreCompactionStaleBoundaryTests {
    @Test(
        "Identity swap between per-entry and compaction-read fails compaction-time revalidation",
        .tags(.lgp9)
    )
    func compactionTimeRevalidationCatchesIdentitySwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Test seam fires inside the actor-isolated removal critical
        // section, AFTER per-entry revalidation has succeeded and
        // BEFORE the compaction read descriptor is opened. Swap seg1
        // for a fresh file at the same path so file identity changes.
        let replacementBytes = Data(repeating: 0x42, count: 4096)
        let seg1Path = seg1URL.path
        let captured = replacementBytes
        await store._setOnBeforeOpenCompactionReadForTesting { _ in
            try FileManager.default.removeItem(atPath: seg1Path)
            try captured.write(to: URL(fileURLWithPath: seg1Path))
        }

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale on compaction-time identity swap"
            )
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // The replacement bytes survived; compaction-time
        // revalidation rejected before any temp create or atomic
        // replacement could overwrite the swapped file.
        let onDisk = try Data(contentsOf: seg1URL)
        #expect(onDisk == replacementBytes)

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Truncate below exportedPrefixEnd between per-entry and compaction-read fails compaction-time revalidation",
        .tags(.lgp9)
    )
    func compactionTimeRevalidationCatchesShorterThanBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Test seam truncates seg1 below `exportedPrefixEnd` while
        // preserving file identity. `O_WRONLY | O_NOFOLLOW` keeps
        // the same inode; `ftruncate(_, 0)` shrinks below any
        // captured `exportedPrefixEnd > 0`.
        let seg1Path = seg1URL.path
        await store._setOnBeforeOpenCompactionReadForTesting { _ in
            let descriptor = seg1Path.withCString { cPath in
                Darwin.open(cPath, O_WRONLY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.ftruncate(descriptor, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale on compaction-time truncation"
            )
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Vanish between per-entry and compaction-read fails compaction-read open as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func compactionReadOpenVanishStaleBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Seam unlinks seg1 from inside the actor-isolated removal
        // critical section, after per-entry revalidation succeeds
        // but before `openat(...)` runs for the compaction read.
        // The compaction-read open hits ENOENT and must classify
        // as `.removalBoundaryStale`, not `.operationFailed(.openSegment)`.
        let seg1Path = seg1URL.path
        await store._setOnBeforeOpenCompactionReadForTesting { _ in
            try FileManager.default.removeItem(atPath: seg1Path)
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on compaction-read vanish")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // No compaction temp left behind: the open failed before any
        // temp creation or atomic replacement could run.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Symlink swap between per-entry and compaction-read fails compaction-read open as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func compactionReadOpenSymlinkStaleBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        let symlinkTarget = directory.appendingPathComponent("untouched-target.bin")
        let targetBytes = Data(repeating: 0xCC, count: 256)
        try targetBytes.write(to: symlinkTarget)

        // Seam unlinks seg1 and plants a symlink at the same path
        // pointing at an unrelated sibling, between per-entry
        // revalidation and compaction-read open. `O_NOFOLLOW`
        // surfaces ELOOP, which must classify as
        // `.removalBoundaryStale`, not `.operationFailed(.openSegment)`.
        let seg1Path = seg1URL.path
        let targetPath = symlinkTarget.path
        await store._setOnBeforeOpenCompactionReadForTesting { _ in
            try FileManager.default.removeItem(atPath: seg1Path)
            try FileManager.default.createSymbolicLink(
                atPath: seg1Path, withDestinationPath: targetPath
            )
        }

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale on compaction-read symlink swap"
            )
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // The symlink at the boundary path was not dereferenced; the
        // unrelated sibling was not modified — no atomic replace ran.
        let resolvedDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: seg1URL.path
        )
        #expect(resolvedDestination == symlinkTarget.path)
        let onTarget = try Data(contentsOf: symlinkTarget)
        #expect(onTarget == targetBytes)

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }
}
