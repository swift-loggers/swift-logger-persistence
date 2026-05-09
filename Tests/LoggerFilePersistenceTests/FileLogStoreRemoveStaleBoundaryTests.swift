import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Stale-boundary coverage for `FileLogStore.removeExportedLogs()`.
/// Each test forces a topology mismatch via out-of-band
/// filesystem mutation between export commit and removal, then
/// asserts removal fails closed with `.removalBoundaryStale`
/// and performs no further mutation.
@Suite("FileLogStore destructive removal — stale boundary")
struct FileLogStoreRemoveStaleBoundaryTests {
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

    private static func setupSingleSegmentExport(
        directory: URL
    ) async throws -> (store: FileLogStore, segmentURL: URL) {
        let store = makeStore(directory: directory, rotation: .never)
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()
        let (exportURL, exportParent) = try makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)
        return (store, directory.appendingPathComponent("log.ndjson"))
    }
}

// MARK: - Missing segment

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment unlinked out-of-band fails removal as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func missingBoundarySegmentRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Out-of-band: unlink the boundary segment between
        // export commit and removal.
        try FileManager.default.removeItem(at: segmentURL)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }
    }
}

// MARK: - Identity mismatch

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment replaced by different file identity fails removal as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func identityMismatchRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Out-of-band: unlink the original file and create a
        // fresh file at the same path.
        try FileManager.default.removeItem(at: segmentURL)
        try Data(repeating: 0x42, count: 4096).write(to: segmentURL)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // The replacement bytes survived: validation fails before
        // any mutation happens.
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk.count == 4096)
    }
}

// MARK: - Identity mismatch detected at per-entry mutation

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment swapped after global validation fails per-entry revalidation",
        .tags(.lgp9)
    )
    func perEntryIdentityRevalidationCatchesPostValidationSwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Pre-stage replacement bytes; the test seam below
        // performs the swap from inside the actor-isolated
        // critical section so it lands AFTER global validation.
        let replacementBytes = Data(repeating: 0x42, count: 4096)
        let segmentPath = segmentURL.path
        let captured = replacementBytes
        await store._setOnBeforeProcessRemovalEntryForTesting { _ in
            try FileManager.default.removeItem(atPath: segmentPath)
            try captured.write(to: URL(fileURLWithPath: segmentPath))
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on identity mismatch")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // Replacement file is preserved: per-entry mutation
        // failed closed before any unlink/compact ran.
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == replacementBytes)
    }
}

// MARK: - Symlink replacement before remove

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment replaced by a symlink fails removal as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func boundarySegmentReplacedBySymlinkRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Out-of-band: unlink the boundary segment and create a
        // symlink at the same path pointing at an unrelated
        // sibling. Removal must fail closed before mutating the
        // boundary path or the symlink target.
        let symlinkTarget = directory.appendingPathComponent("untouched-target.bin")
        let targetBytes = Data(repeating: 0xAA, count: 256)
        try targetBytes.write(to: symlinkTarget)

        try FileManager.default.removeItem(at: segmentURL)
        try FileManager.default.createSymbolicLink(
            at: segmentURL, withDestinationURL: symlinkTarget
        )

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on symlink replacement")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // The boundary path is still the planted symlink (not
        // unlinked or replaced) and the symlink target was not
        // modified: validation fails before any mutation.
        let resolvedDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: segmentURL.path
        )
        #expect(resolvedDestination == symlinkTarget.path)
        let onTarget = try Data(contentsOf: symlinkTarget)
        #expect(onTarget == targetBytes)
    }
}

// MARK: - Post-global-validation segment vanish + symlink swap

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment vanishing after global validation fails per-entry revalidation",
        .tags(.lgp9)
    )
    func perEntryRevalidationCatchesPostValidationVanish() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Test seam unlinks the boundary segment from inside
        // the actor-isolated critical section so the swap
        // lands after global validation but before per-entry
        // boundary revalidation.
        let segmentPath = segmentURL.path
        await store._setOnBeforeProcessRemovalEntryForTesting { _ in
            try FileManager.default.removeItem(atPath: segmentPath)
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on per-entry vanish")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }
    }

    @Test(
        "Boundary segment replaced by symlink after global validation fails per-entry revalidation",
        .tags(.lgp9)
    )
    func perEntryRevalidationCatchesPostValidationSymlinkSwap() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        let symlinkTarget = directory.appendingPathComponent("untouched-target.bin")
        let targetBytes = Data(repeating: 0xBB, count: 256)
        try targetBytes.write(to: symlinkTarget)

        let segmentPath = segmentURL.path
        let targetPath = symlinkTarget.path
        await store._setOnBeforeProcessRemovalEntryForTesting { _ in
            try FileManager.default.removeItem(atPath: segmentPath)
            try FileManager.default.createSymbolicLink(
                atPath: segmentPath, withDestinationPath: targetPath
            )
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on per-entry symlink swap")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // The boundary path is still the planted symlink (not
        // unlinked or replaced) and the symlink target was not
        // modified — failure happens before any unlink/compact
        // runs against the dereferenced path.
        let resolvedDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: segmentURL.path
        )
        #expect(resolvedDestination == symlinkTarget.path)
        let onTarget = try Data(contentsOf: symlinkTarget)
        #expect(onTarget == targetBytes)
    }
}

// MARK: - Non-duplicate enumeration failure

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Non-duplicate rotated-topology enumeration failure projects to .operationFailed(.validateBoundary)",
        .tags(.lgp6, .lgp9, .lgp39)
    )
    func nonDuplicateRotatedTopologyEnumerationFailureProjectsAsValidateBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: policy)
        )

        let envelope = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        try await store.append(envelope)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Inject a non-duplicate enumeration failure shape via
        // the override seam: a generic POSIX I/O error with no
        // duplicate-sequence marker. The dispatch must route
        // this through `.operationFailed(.validateBoundary)`,
        // not through `.removalBoundaryStale`.
        let injectedURL = directory.appendingPathComponent("log.000001.ndjson")
        let injectedContext = FileSystemErrorContext(
            domain: NSPOSIXErrorDomain,
            code: Int(EBADF),
            description: "synthetic enumeration failure"
        )
        let injectedURLPath = injectedURL
        await store._setRotatedTopologyOverrideForTesting {
            .operationFailed(
                operation: .enumerateSegments,
                url: injectedURLPath,
                context: injectedContext
            )
        }

        do {
            try await store.removeExportedLogs()
            Issue.record("expected operationFailed(.validateBoundary)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, context):
                #expect(operation == .validateBoundary)
                #expect(url == injectedURL)
                #expect(context == injectedContext)
            default:
                Issue.record("expected operationFailed(.validateBoundary), got \(error)")
            }
        }
    }
}

// MARK: - Ambiguous `.bySize` topology

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "`.bySize` duplicate-sequence rotated file fails removal as .removalBoundaryStale",
        .tags(.lgp6, .lgp9, .lgp39)
    )
    func ambiguousRotatedTopologyRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: policy)
        )

        for sequence in 1 ... 2 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
        }
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Plant a duplicate-sequence file (extra zero padding
        // parses as the same numeric sequence as `log.000001`).
        let duplicateURL = directory.appendingPathComponent("log.0000001.ndjson")
        try Data("PLANTED\n".utf8).write(to: duplicateURL)

        let seg1URL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let seg2URL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )
        let seg1Before = try Data(contentsOf: seg1URL)
        let seg2Before = try Data(contentsOf: seg2URL)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale on ambiguous topology")
        } catch {
            switch error {
            case .removalBoundaryStale:
                break
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }

        // Neither boundary segment was mutated.
        let seg1After = try Data(contentsOf: seg1URL)
        let seg2After = try Data(contentsOf: seg2URL)
        #expect(seg1After == seg1Before)
        #expect(seg2After == seg2Before)
    }
}

// MARK: - Size shorter than exportedPrefixEnd

extension FileLogStoreRemoveStaleBoundaryTests {
    @Test(
        "Boundary segment truncated below exportedPrefixEnd fails removal as .removalBoundaryStale",
        .tags(.lgp9)
    )
    func segmentShorterThanBoundaryRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, segmentURL) = try await Self.setupSingleSegmentExport(
            directory: directory
        )

        // Out-of-band: shrink the boundary segment below
        // exportedPrefixEnd while preserving file identity.
        let descriptor = segmentURL.path.withCString { cPath in
            Darwin.open(cPath, O_WRONLY | O_NOFOLLOW)
        }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        #expect(Darwin.ftruncate(descriptor, 0) == 0)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            switch error {
            case let .removalBoundaryStale(url, _):
                #expect(url == segmentURL)
            default:
                Issue.record("expected .removalBoundaryStale, got \(error)")
            }
        }
    }
}
