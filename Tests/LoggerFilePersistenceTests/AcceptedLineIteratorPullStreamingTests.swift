import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Pull-based streaming conformance tests for `AcceptedLineIterator`.
///
/// These prove the iterator does not eagerly scan or buffer
/// unconsumed lines.
@Suite("AcceptedLineIterator pull-based streaming")
struct AcceptedLineIteratorPullStreamingTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
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

extension AcceptedLineIteratorPullStreamingTests {
    @Test(
        "Pulling exactly one line does not read the segment past the chunk that contained that line",
        .tags(.lgp14)
    )
    func pullingOneLineDoesNotEagerlyScanSegment() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Many small accepted lines so the segment spans more than
        // one 64 KiB scanner chunk. After the first pull, the
        // iterator's chunk-read counter must remain bounded; it
        // must NOT have read the whole file to stage line 2.
        let totalLines = 4096
        var bytes = Data()
        for sequence in 1 ... totalLines {
            bytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        try Self.write(
            bytes,
            to: directory.appendingPathComponent("log.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let iterator = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        ).makeAsyncIterator()

        // Before the first pull, no chunks have been read.
        #expect(iterator.chunkReadCountForTesting == 0)

        let first = try await iterator.next()
        #expect(first != nil)
        let chunksAfterFirstPull = iterator.chunkReadCountForTesting
        // The first pull reads at most one or two chunks (enough to
        // find the first LF). It must not have read the whole file.
        let totalChunks = (bytes.count + 65535) / 65536
        #expect(chunksAfterFirstPull < totalChunks)
    }

    @Test(
        "A second pull advances chunk reads only when the next line crosses a chunk boundary",
        .tags(.lgp14)
    )
    func secondPullExpandsReadsOnlyAsNeeded() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // 4096 short lines so multiple lines live in a single chunk.
        // Pulling line 2 must not require a new chunk.
        let totalLines = 4096
        var bytes = Data()
        for sequence in 1 ... totalLines {
            bytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        try Self.write(
            bytes,
            to: directory.appendingPathComponent("log.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let iterator = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        ).makeAsyncIterator()

        _ = try await iterator.next()
        let chunksAfterFirstPull = iterator.chunkReadCountForTesting
        _ = try await iterator.next()
        let chunksAfterSecondPull = iterator.chunkReadCountForTesting
        // Lines 1 and 2 share a chunk; chunk count is unchanged.
        #expect(chunksAfterFirstPull == chunksAfterSecondPull)
    }

    @Test(
        "First pull does not prefetch the next segment: corruption in segment 2 must not surface",
        .tags(.lgp14, .lgp17)
    )
    func iteratorDoesNotPrefetchNextSegmentDuringFirstPull() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Segment 1 has one accepted line; segment 2 is interior
        // corruption. If the iterator pre-scanned segment 2 during
        // the first pull, the corruption would surface.
        let segment1Line = try Self.canonicalLine(sequence: 1)
        try Self.write(
            segment1Line,
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        try Self.write(
            Data("[1,2,3]".utf8) + Data([0x0A]),
            to: directory.appendingPathComponent("log.000002.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let iterator = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        ).makeAsyncIterator()

        let pulled = try await iterator.next()
        #expect(pulled == segment1Line)
    }

    @Test(
        "Next segment is opened only on the pull that advances past segment 1's content",
        .tags(.lgp14)
    )
    func iteratorOpensNextSegmentOnlyOnAdvancingPull() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let segment1Line = try Self.canonicalLine(sequence: 1)
        let segment2Line = try Self.canonicalLine(sequence: 2)
        try Self.write(
            segment1Line,
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        let segment2URL = directory.appendingPathComponent("log.000002.ndjson")
        try Self.write(segment2Line, to: segment2URL)

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let iterator = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        ).makeAsyncIterator()

        let pull1 = try await iterator.next()
        #expect(pull1 == segment1Line)

        // Removing segment 2 proves it was not pre-opened.
        try FileManager.default.removeItem(at: segment2URL)

        do {
            _ = try await iterator.next()
            Issue.record("expected operationFailed(.openSegment)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .openSegment)
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "Dropping the iterator after the first pull triggers segment release (early termination cleanup)",
        .tags(.lgp14)
    )
    func droppingIteratorTriggersSegmentRelease() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try Self.write(
            try Self.canonicalLine(sequence: 1),
            to: directory.appendingPathComponent("log.000001.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )

        let observer = ReleaseObserver()
        do {
            let iterator = AcceptedLineIterator.acceptedLines(
                configuration: configuration
            ).makeAsyncIterator()
            iterator._releaseObserverForTesting = { observer.record() }
            _ = try await iterator.next()
            #expect(observer.releaseCount == 0)
        }
        // The `do` scope drops the iterator; the class deinit runs
        // `releaseCurrentSegment()` exactly once for the active segment.
        #expect(observer.releaseCount == 1)
    }
}

/// Lock-guarded release counter for cleanup assertions.
private final class ReleaseObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
