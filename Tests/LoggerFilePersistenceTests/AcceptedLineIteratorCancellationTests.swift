import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Cancellation regression coverage for accepted-line iteration and
/// scanner-owned boundary resolution.
@Suite("AcceptedLineIterator cancellation observes Task.isCancelled")
struct AcceptedLineIteratorCancellationTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static var hugeNoLFByteCount: Int { 5 * 1_048_576 }
}

extension AcceptedLineIteratorCancellationTests {
    @Test(
        "AcceptedLineIterator.next() returns nil promptly under Task cancellation",
        .tags(.lgp14, .lgp19)
    )
    func iteratorReturnsNilPromptlyUnderTaskCancellation() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        try Data(repeating: 0x41, count: Self.hugeNoLFByteCount).write(
            to: directory.appendingPathComponent("log.ndjson")
        )

        let chunkReadCount: Int = await Task {
            let stream = AcceptedLineIterator.acceptedLines(
                configuration: .init(directory: directory)
            )
            let iterator = stream.makeAsyncIterator()
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try? await iterator.next()
            return iterator.chunkReadCountForTesting
        }.value

        // Cancellation must stop before scanner reads.
        #expect(chunkReadCount == 0)
    }

    @Test(
        "resolveBoundary ignores Task cancellation",
        .tags(.lgp14, .lgp19, .lgp24, .lgp25)
    )
    func resolveBoundaryIsCancellationNeutral() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let url = directory.appendingPathComponent("log.ndjson")
        // Boundary resolution is cancellation-neutral.
        let envelope = try PersistentLogEnvelope(
            id: FileLogStoreTestSupport.baselineId,
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.test.v1+json",
            hints: [:],
            payload: Data([0x01, 0x02, 0x03])
        )
        let line = try CanonicalEnvelopeLineEncoder().encode(envelope)
        let totalLines = 5000
        var bytes = Data()
        for _ in 0 ..< totalLines {
            bytes.append(line)
        }
        let trailingPartial = Data([0x7B, 0x22]) // `{"`
        try (bytes + trailingPartial).write(to: url)

        let resolution = try await Task { () throws -> RecoverablePrefixScanner.BoundaryResolution in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            withUnsafeCurrentTask { $0?.cancel() }
            return try RecoverablePrefixScanner.resolveBoundary(
                handle: handle, segmentURL: url
            )
        }.value

        switch resolution {
        case let .boundary(boundary):
            #expect(boundary == UInt64(bytes.count))
        case .interiorCorruption:
            Issue.record("expected .boundary, got .interiorCorruption")
        }
    }
}
