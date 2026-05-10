import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Compaction-time stale-boundary coverage for destructive removal.
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

        // Append post-boundary bytes so compaction runs after per-entry revalidation.
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
        "Compaction-read identity swap fails stale",
        .tags(.lgp9)
    )
    func compactionTimeRevalidationCatchesIdentitySwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Swap seg1 after per-entry revalidation and before compaction read open.
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

        // Replacement bytes preserved; no atomic replacement ran.
        let onDisk = try Data(contentsOf: seg1URL)
        #expect(onDisk == replacementBytes)

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Compaction-read truncation fails stale",
        .tags(.lgp9)
    )
    func compactionTimeRevalidationCatchesShorterThanBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Truncate seg1 below `exportedPrefixEnd` while preserving identity.
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

        // Planted truncated state preserved; no atomic replacement ran.
        let onDisk = try Data(contentsOf: seg1URL)
        #expect(onDisk.isEmpty)

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Compaction-read vanish fails stale",
        .tags(.lgp9)
    )
    func compactionReadOpenVanishStaleBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Unlink seg1 after per-entry revalidation and before compaction read open.
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

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Compaction-read symlink swap fails stale",
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

        // Swap seg1 to a symlink before compaction read open.
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

        // Symlink not dereferenced; symlink target bytes untouched.
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

    @Test(
        "Pre-replace identity swap fails stale",
        .tags(.lgp9)
    )
    func preReplaceRevalidationCatchesIdentitySwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        // Swap seg1 after compaction-read revalidation and before pre-replace revalidation.
        let replacementBytes = Data(repeating: 0x42, count: 4096)
        let seg1Path = seg1URL.path
        let captured = replacementBytes
        await store._setOnBeforePreReplaceRevalidateForTesting { _ in
            try FileManager.default.removeItem(atPath: seg1Path)
            try captured.write(to: URL(fileURLWithPath: seg1Path))
        }

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale on pre-replace identity swap"
            )
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // Replacement bytes preserved; no atomic replacement ran.
        let onDisk = try Data(contentsOf: seg1URL)
        #expect(onDisk == replacementBytes)

        // No compaction temp left behind.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!entries.contains(where: { $0.hasPrefix(".swift-logger-compact-") }))
    }

    @Test(
        "Pre-replace symlink swap fails stale",
        .tags(.lgp9)
    )
    func preReplaceRevalidationCatchesSymlinkSwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, seg1URL) = try await Self.setupRotatedCompactionFixture(
            directory: directory
        )

        let symlinkTarget = directory.appendingPathComponent("untouched-target.bin")
        let targetBytes = Data(repeating: 0xCC, count: 256)
        try targetBytes.write(to: symlinkTarget)

        // Swap seg1 to a symlink before pre-replace revalidation.
        let seg1Path = seg1URL.path
        let targetPath = symlinkTarget.path
        await store._setOnBeforePreReplaceRevalidateForTesting { _ in
            try FileManager.default.removeItem(atPath: seg1Path)
            try FileManager.default.createSymbolicLink(
                atPath: seg1Path, withDestinationPath: targetPath
            )
        }

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale on pre-replace symlink swap"
            )
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == seg1URL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // Symlink not dereferenced; symlink target bytes untouched.
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
