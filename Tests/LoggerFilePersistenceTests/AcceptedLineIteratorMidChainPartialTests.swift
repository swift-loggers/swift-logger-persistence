import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for non-final trailing partial recovery.
@Suite("AcceptedLineIterator non-final trailing partial")
struct AcceptedLineIteratorMidChainPartialTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func canonicalLine(sequence: UInt64) throws -> Data {
        let envelope = try PersistentLogEnvelope(
            id: FileLogStoreTestSupport.baselineId,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.test.v1+json",
            hints: [:],
            payload: Data([0x01, 0x02, 0x03])
        )
        return try CanonicalEnvelopeLineEncoder().encode(envelope)
    }
}

extension AcceptedLineIteratorMidChainPartialTests {
    @Test(
        "Non-final trailing partial hard-stops after accepted prefix",
        .tags(.lgp14, .lgp15, .lgp16, .lgp17)
    )
    func trailingPartialInNonFinalSegmentHardStops() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Segment 1: one accepted line followed by a non-LF tail.
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        let trailingPartial = Data([0x7B, 0x22]) // `{"`
        try (acceptedLine + trailingPartial).write(
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        // Segment 2: a clean accepted line. Must never be visible
        // to the consumer because segment 1's recoverable prefix
        // ends mid-chain.
        let segment2URL = directory.appendingPathComponent("log.000002.ndjson")
        try (try Self.canonicalLine(sequence: 2)).write(to: segment2URL)

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        let iterator = stream.makeAsyncIterator()

        // First pull yields segment 1's accepted line verbatim.
        let first = try await iterator.next()
        #expect(first == acceptedLine)

        // If the iterator wrongly advanced to segment 2, opening
        // the now-removed file would fail with `.openSegment` on
        // `log.000002.ndjson` instead of the expected
        // `.readSegmentBytes` on `log.000001.ndjson`.
        try FileManager.default.removeItem(at: segment2URL)

        // Second pull observes segment 1's trailing partial. Because
        // segment 2 was discovered, this is mid-chain and must
        // hard-stop.
        do {
            _ = try await iterator.next()
            Issue.record("expected operationFailed(.readSegmentBytes)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .readSegmentBytes)
                #expect(url.lastPathComponent == "log.000001.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }

        // Iterator is terminated; further pulls return nil.
        let after = try await iterator.next()
        #expect(after == nil)
    }
}
