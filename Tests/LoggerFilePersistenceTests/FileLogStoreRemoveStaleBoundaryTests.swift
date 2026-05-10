import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Stale-boundary coverage for `FileLogStore.removeExportedLogs()`.
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

    private static func castRemoveError(
        _ error: any Error
    ) -> FileLogStoreRemoveError? {
        guard let removeError = error as? FileLogStoreRemoveError else {
            Issue.record(
                "expected FileLogStoreRemoveError, got \(type(of: error)): \(error)"
            )
            return nil
        }
        return removeError
    }

    private static func expectRemovalBoundaryStale(
        _ error: any Error,
        url expectedURL: URL? = nil
    ) {
        guard let removeError = Self.castRemoveError(error) else { return }
        switch removeError {
        case let .removalBoundaryStale(url, _):
            if let expectedURL {
                #expect(url == expectedURL)
            }
        default:
            Issue.record("expected .removalBoundaryStale, got \(removeError)")
        }
    }

    private static func expectFileSystemContext(
        _ context: FileSystemErrorContext,
        matches expected: FileSystemErrorContext
    ) {
        #expect(context.domain == expected.domain)
        #expect(context.code == expected.code)
        #expect(context.description == expected.description)
    }

    private static func expectValidateBoundaryOperationFailed(
        _ error: any Error,
        expectedURL: URL,
        expectedContext: FileSystemErrorContext
    ) {
        guard let removeError = Self.castRemoveError(error) else { return }
        switch removeError {
        case let .operationFailed(operation, url, context):
            #expect(operation == .validateBoundary)
            #expect(url == expectedURL)
            Self.expectFileSystemContext(context, matches: expectedContext)
        default:
            Issue.record(
                "expected operationFailed(.validateBoundary), got \(removeError)"
            )
        }
    }

    private static func withInstalledSeam(
        install: () async -> Void,
        cleanup: () async -> Void,
        body: () async throws -> Void
    ) async throws {
        await install()
        var capturedError: (any Error)?
        do {
            try await body()
        } catch {
            capturedError = error
        }
        await cleanup()
        if let capturedError { throw capturedError }
    }

    private static func withInstalledSeam<Handler>(
        setter: @Sendable @escaping (Handler?) async -> Void,
        handler: Handler,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            install: { await setter(handler) },
            cleanup: { await setter(nil) },
            body: body
        )
    }

    private static func withProcessRemovalEntrySeam(
        on store: FileLogStore,
        handler: @Sendable @escaping (URL) async throws -> Void,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            setter: { await store._setOnBeforeProcessRemovalEntryForTesting($0) },
            handler: handler,
            body: body
        )
    }

    private static func withRotatedTopologyOverride(
        on store: FileLogStore,
        handler: @Sendable @escaping () -> InternalReadError?,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            setter: { await store._setRotatedTopologyOverrideForTesting($0) },
            handler: handler,
            body: body
        )
    }

    private static func closeDescriptorAndRecordUnexpectedError(_ descriptor: Int32) {
        if Darwin.close(descriptor) != 0 {
            Issue.record("close(descriptor) failed with errno \(errno)")
        }
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

        try FileManager.default.removeItem(at: segmentURL)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            Self.expectRemovalBoundaryStale(error, url: segmentURL)
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

        try FileManager.default.removeItem(at: segmentURL)
        try Data(repeating: 0x42, count: 4096).write(to: segmentURL)

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            Self.expectRemovalBoundaryStale(error, url: segmentURL)
        }

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

        let replacementBytes = Data(repeating: 0x42, count: 4096)
        let segmentPath = segmentURL.path
        let captured = replacementBytes
        try await Self.withProcessRemovalEntrySeam(
            on: store,
            handler: { _ in
                try FileManager.default.removeItem(atPath: segmentPath)
                try captured.write(to: URL(fileURLWithPath: segmentPath))
            },
            body: {
                do {
                    try await store.removeExportedLogs()
                    Issue.record("expected .removalBoundaryStale on identity mismatch")
                } catch {
                    Self.expectRemovalBoundaryStale(error, url: segmentURL)
                }
            }
        )

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
            Self.expectRemovalBoundaryStale(error, url: segmentURL)
        }

        #expect(
            try FileManager.default.attributesOfItem(atPath: segmentURL.path)[.type]
                as? FileAttributeType == .typeSymbolicLink
        )
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

        let segmentPath = segmentURL.path
        try await Self.withProcessRemovalEntrySeam(
            on: store,
            handler: { _ in
                try FileManager.default.removeItem(atPath: segmentPath)
            },
            body: {
                do {
                    try await store.removeExportedLogs()
                    Issue.record("expected .removalBoundaryStale on per-entry vanish")
                } catch {
                    Self.expectRemovalBoundaryStale(error, url: segmentURL)
                }
            }
        )

        #expect(!FileManager.default.fileExists(atPath: segmentURL.path))
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
        try await Self.withProcessRemovalEntrySeam(
            on: store,
            handler: { _ in
                try FileManager.default.removeItem(atPath: segmentPath)
                try FileManager.default.createSymbolicLink(
                    atPath: segmentPath, withDestinationPath: targetPath
                )
            },
            body: {
                do {
                    try await store.removeExportedLogs()
                    Issue.record("expected .removalBoundaryStale on per-entry symlink swap")
                } catch {
                    Self.expectRemovalBoundaryStale(error, url: segmentURL)
                }
            }
        )

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

        let injectedURL = directory.appendingPathComponent("log.000001.ndjson")
        let injectedContext = FileSystemErrorContext(
            domain: NSPOSIXErrorDomain,
            code: Int(EBADF),
            description: "synthetic enumeration failure"
        )
        try await Self.withRotatedTopologyOverride(
            on: store,
            handler: {
                .operationFailed(
                    operation: .enumerateSegments,
                    url: injectedURL,
                    context: injectedContext
                )
            },
            body: {
                do {
                    try await store.removeExportedLogs()
                    Issue.record("expected operationFailed(.validateBoundary)")
                } catch {
                    Self.expectValidateBoundaryOperationFailed(
                        error,
                        expectedURL: injectedURL,
                        expectedContext: injectedContext
                    )
                }
            }
        )
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
            Self.expectRemovalBoundaryStale(error)
        }

        let seg1After = try Data(contentsOf: seg1URL)
        let seg2After = try Data(contentsOf: seg2URL)
        #expect(seg1After == seg1Before)
        #expect(seg2After == seg2Before)
        #expect(FileManager.default.fileExists(atPath: duplicateURL.path))
        #expect(try Data(contentsOf: duplicateURL) == Data("PLANTED\n".utf8))
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

        let descriptor = segmentURL.path.withCString { cPath in
            Darwin.open(cPath, O_WRONLY | O_NOFOLLOW)
        }
        try #require(descriptor >= 0)
        defer { Self.closeDescriptorAndRecordUnexpectedError(descriptor) }
        #expect(Darwin.ftruncate(descriptor, 0) == 0)
        #expect(
            try FileManager.default.attributesOfItem(atPath: segmentURL.path)[.size]
                as? NSNumber == 0
        )

        do {
            try await store.removeExportedLogs()
            Issue.record("expected .removalBoundaryStale")
        } catch {
            Self.expectRemovalBoundaryStale(error, url: segmentURL)
        }
    }
}
