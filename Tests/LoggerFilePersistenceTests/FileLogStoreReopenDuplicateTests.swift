import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Reopen behavior on ambiguous segment topology + appends at
/// the recoverable-prefix boundary over large clean prefixes.
extension FileLogStoreReopenTests {
    @Test(
        "Reopen over a large clean .never segment appends at the recoverable-prefix boundary",
        .tags(.lgp14, .lgp25, .lgp27)
    )
    func reopenOverLargeCleanNeverSegmentAppendsAtRecoverableBoundary() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let totalLines = 5000
        var prefixBytes = Data()
        for sequence in 1 ... totalLines {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence),
                payload: Data([0x01])
            )
            let line = try CanonicalEnvelopeLineEncoder().encode(envelope)
            prefixBytes.append(line)
        }
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        try prefixBytes.write(to: segmentURL)

        let store = FileLogStore(configuration: .init(directory: directory))
        let nextEnvelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: UInt64(totalLines + 1),
            payload: Data([0x01])
        )
        let nextLine = try CanonicalEnvelopeLineEncoder().encode(nextEnvelope)
        try await store.append(nextEnvelope)
        try await store.flush()

        let onDisk = try Data(contentsOf: segmentURL)
        #expect(onDisk == prefixBytes + nextLine)
    }

    @Test(
        "Reopen with a clean .bySize latest segment plus trailing partial truncates and admits at the boundary",
        .tags(.lgp14, .lgp15, .lgp16, .lgp24, .lgp25, .lgp39)
    )
    func reopenBySizeLatestSegmentTruncatesPartialAndAdmitsAtBoundary() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let totalLines = 4000
        var prefixBytes = Data()
        for sequence in 1 ... totalLines {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence),
                payload: Data([0x01])
            )
            prefixBytes.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        // Trailing partial bytes after the last accepted LF.
        let trailingPartial = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let segmentURL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        try (prefixBytes + trailingPartial).write(to: segmentURL)

        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(configuration: .init(
            directory: directory, rotation: policy
        ))
        let nextEnvelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: UInt64(totalLines + 1),
            payload: Data([0x01])
        )
        let nextLine = try CanonicalEnvelopeLineEncoder().encode(nextEnvelope)
        try await store.append(nextEnvelope)
        try await store.flush()

        let onDisk = try Data(contentsOf: segmentURL)
        // Trailing partial bytes are gone; next admit lands at the
        // recoverable-prefix boundary.
        #expect(onDisk == prefixBytes + nextLine)
    }
}

extension FileLogStoreReopenTests {
    /// Reopen on duplicate numeric segment index must fail closed
    /// without admitting a new segment.
    @Test(
        "Reopen with duplicate numeric segment index fails closed and does not mutate any segment",
        .tags(.lgp24, .lgp25, .lgp39)
    )
    func reopenWithDuplicateNumericSegmentIndexFailsClosed() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let envelope = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        let line = try CanonicalEnvelopeLineEncoder().encode(envelope)
        try line.write(to: directory.appendingPathComponent("log.1.ndjson"))
        try line.write(to: directory.appendingPathComponent("log.000001.ndjson"))

        let snapshotBefore = try Self.directorySnapshot(directory)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: try RotationPolicy.bySize(
                maxSegmentBytes: FileLogStore.maxEncodedLineBytes
            )
        ))

        do {
            try await store.append(
                try FileLogStoreTestSupport.makeEnvelope(sequence: 2)
            )
            Issue.record("expected FileLogStoreError.operationFailed")
        } catch let error as FileLogStoreError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                let conflictNames: Set = ["log.1.ndjson", "log.000001.ndjson"]
                #expect(conflictNames.contains(url.lastPathComponent))
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }

        // Failed reopen is non-destructive: directory listing and
        // both segment payloads are unchanged.
        let snapshotAfter = try Self.directorySnapshot(directory)
        #expect(snapshotBefore == snapshotAfter)
    }

    /// Captures the directory listing plus both duplicate segments'
    /// payload bytes so the test can assert non-destructive reopen.
    private static func directorySnapshot(_ directory: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in entries {
            snapshot[name] = try Data(
                contentsOf: directory.appendingPathComponent(name)
            )
        }
        return snapshot
    }
}
