import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for yielding scanner-owned accepted bytes.
@Suite("AcceptedLineIterator no reread after classification")
struct AcceptedLineIteratorRereadTests {
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

extension AcceptedLineIteratorRereadTests {
    @Test(
        "Iterator yields scanner-owned accepted bytes without reread",
        .tags(.lgp14, .lgp27)
    )
    func iteratorYieldsSingleChunkWithoutReread() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // All accepted lines fit in one scanner chunk; reread would advance
        // the descriptor and force extra scanner reads.
        var bytes = Data()
        let lineCount = 100
        for sequence in 1 ... lineCount {
            bytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        try bytes.write(to: directory.appendingPathComponent("log.ndjson"))

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        let iterator = stream.makeAsyncIterator()
        var consumed = 0
        while try await iterator.next() != nil {
            consumed += 1
        }
        #expect(consumed == lineCount)
        // All lines fit in one chunk; the scanner reports exactly
        // one non-empty chunk read across the whole iteration.
        #expect(iterator.chunkReadCountForTesting == 1)
    }
}
