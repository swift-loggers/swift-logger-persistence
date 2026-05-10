import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Failure-path coverage for destructive removal retry boundaries.
@Suite("FileLogStore destructive removal — failure retains remaining")
struct FileLogStoreRemoveFailureTests {
    private struct SentinelError: Error, CustomNSError {
        static let errorDomain = "FileLogStoreRemoveFailureTests.SentinelError"
        static let staticErrorCode: Int = 0
        var errorCode: Int { Self.staticErrorCode }
    }

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

    /// Asserts operation failure and pinned sentinel NSError projection.
    private static func expectOperationFailedPayload(
        _ error: any Error,
        operation expectedOperation: FileLogStoreRemoveOperation,
        expectedURL: URL? = nil
    ) {
        guard let removeError = Self.castRemoveError(error) else { return }
        switch removeError {
        case let .operationFailed(operation, url, context):
            #expect(operation == expectedOperation)
            if let expectedURL {
                #expect(url == expectedURL)
            }
            #expect(context.domain == SentinelError.errorDomain)
            #expect(context.code == SentinelError.staticErrorCode)
        default:
            Issue.record(
                "expected .operationFailed(.\(expectedOperation)), got \(removeError)"
            )
        }
    }

    /// Asserts body throws the expected operation failure.
    private static func expectOperationFailed(
        operation: FileLogStoreRemoveOperation,
        expectedURL: URL? = nil,
        when body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected .operationFailed(.\(operation)) but call succeeded")
        } catch {
            Self.expectOperationFailedPayload(
                error, operation: operation, expectedURL: expectedURL
            )
        }
    }

    private static func expectNoRemovalBoundary(
        when body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected .noExportedRemovalBoundary")
        } catch {
            guard let removeError = Self.castRemoveError(error) else { return }
            switch removeError {
            case .noExportedRemovalBoundary:
                break
            default:
                Issue.record("expected .noExportedRemovalBoundary, got \(removeError)")
            }
        }
    }

    /// Runs body with seam installed and clears it before returning.
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

    private static func withReopenActiveSegmentFailure(
        on store: FileLogStore,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            install: {
                await store._setOnBeforeReopenActiveSegmentForTesting { _ in
                    throw SentinelError()
                }
            },
            cleanup: {
                await store._setOnBeforeReopenActiveSegmentForTesting(nil)
            },
            body: body
        )
    }

    private static func withProcessRemovalEntryFailure(
        on store: FileLogStore,
        target: URL,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            install: {
                await store._setOnBeforeProcessRemovalEntryForTesting { url in
                    if url == target { throw SentinelError() }
                }
            },
            cleanup: {
                await store._setOnBeforeProcessRemovalEntryForTesting(nil)
            },
            body: body
        )
    }

    /// Creates three rotated segments and captures a removal boundary.
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
        let (store, exportParent) = try await Self.setupBoundaryWithThreeRotatedSegments(
            directory: directory
        )
        defer { FileLogStoreTestSupport.remove(exportParent) }

        let seg1 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let seg2 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )
        let seg3 = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 3
        )
        #expect(FileManager.default.fileExists(atPath: seg1.path))
        #expect(FileManager.default.fileExists(atPath: seg2.path))
        #expect(FileManager.default.fileExists(atPath: seg3.path))

        let failTarget = seg2
        try await Self.withProcessRemovalEntryFailure(
            on: store, target: failTarget
        ) {
            await Self.expectOperationFailed(
                operation: .validateBoundary, expectedURL: failTarget
            ) {
                try await store.removeExportedLogs()
            }

            // Failed entry and later entries remain retryable.
            #expect(!FileManager.default.fileExists(atPath: seg1.path))
            #expect(FileManager.default.fileExists(atPath: seg2.path))
            #expect(FileManager.default.fileExists(atPath: seg3.path))
        }

        try await store.removeExportedLogs()

        #expect(!FileManager.default.fileExists(atPath: seg1.path))
        #expect(!FileManager.default.fileExists(atPath: seg2.path))
        #expect(FileManager.default.fileExists(atPath: seg3.path))
        #expect(try Data(contentsOf: seg3).isEmpty)

        await Self.assertNoRemovalBoundaryAfterDrain(store: store)
    }

    @Test(
        "Reopen failure after mutation advances boundary",
        .tags(.lgp9, .lgp27)
    )
    func reopenFailureAfterMutationAdvancesBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        try await Self.withReopenActiveSegmentFailure(on: store) {
            await Self.expectOperationFailed(operation: .reopenActiveSegment) {
                try await store.removeExportedLogs()
            }

            let segmentURL = directory.appendingPathComponent("log.ndjson")
            let onDisk = try Data(contentsOf: segmentURL)
            #expect(onDisk == line2)
        }

        try await store.removeExportedLogs()
        await Self.assertNoRemovalBoundaryAfterDrain(store: store)
    }

    @Test(
        "Writer-offset reset failure advances boundary",
        .tags(.lgp9, .lgp27)
    )
    func writerOffsetResetFailureAfterActiveSegmentResetAdvancesBoundary() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        try await Self.withReopenActiveSegmentFailure(on: store) {
            await Self.expectOperationFailed(operation: .reopenActiveSegment) {
                try await store.removeExportedLogs()
            }

            let segmentURL = directory.appendingPathComponent("log.ndjson")
            let onDisk = try Data(contentsOf: segmentURL)
            #expect(onDisk.isEmpty)
        }

        try await store.removeExportedLogs()
        await Self.assertNoRemovalBoundaryAfterDrain(store: store)
    }

    @Test(
        "Append after failed active reset stays canonical",
        .tags(.lgp9, .lgp24, .lgp25, .lgp27)
    )
    func appendAfterFailedResetProducesCanonicalBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        try await Self.withReopenActiveSegmentFailure(on: store) {
            await Self.expectOperationFailed(operation: .reopenActiveSegment) {
                try await store.removeExportedLogs()
            }
        }

        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2)

        try await store.removeExportedLogs()
        await Self.assertNoRemovalBoundaryAfterDrain(store: store)
    }

    @Test(
        "Append after failed compaction reopen stays canonical",
        .tags(.lgp9, .lgp24, .lgp25, .lgp27)
    )
    func appendAfterFailedReopenAfterCompactionProducesCanonicalBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope1)
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 2, payload: Data([0x02])
        )
        try await store.append(envelope2)
        try await store.flush()
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)

        try await Self.withReopenActiveSegmentFailure(on: store) {
            await Self.expectOperationFailed(operation: .reopenActiveSegment) {
                try await store.removeExportedLogs()
            }
        }

        let envelope3 = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 3, payload: Data([0x03])
        )
        try await store.append(envelope3)
        try await store.flush()
        let line3 = try CanonicalEnvelopeLineEncoder().encode(envelope3)

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == line2 + line3)

        try await store.removeExportedLogs()
        await Self.assertNoRemovalBoundaryAfterDrain(store: store)
    }

    /// Asserts the next removal call reports no retained boundary.
    private static func assertNoRemovalBoundaryAfterDrain(
        store: FileLogStore
    ) async {
        await Self.expectNoRemovalBoundary {
            try await store.removeExportedLogs()
        }
    }
}
