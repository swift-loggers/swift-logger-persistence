import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Production-shape contract tests for `RecoverablePrefixScanner`.
@Suite("RecoverablePrefixScanner production-shape contract")
struct RecoverablePrefixScannerBoundaryTests {
    private static func uniqueSegmentURL() throws -> URL {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("log.000001.ndjson")
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

extension RecoverablePrefixScannerBoundaryTests {
    @Test(
        "resolveBoundary over a large clean prefix returns the recoverable-prefix end",
        .tags(.lgp14, .lgp27)
    )
    func resolveBoundaryOverLargeCleanPrefix() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        // 10_000 short accepted lines exercises the per-line walk.
        let totalLines = 10000
        var bytes = Data()
        var expectedBoundary: UInt64 = 0
        for sequence in 1 ... totalLines {
            let line = try Self.canonicalLine(sequence: UInt64(sequence))
            bytes.append(line)
            expectedBoundary += UInt64(line.count)
        }
        try bytes.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolution = try RecoverablePrefixScanner.resolveBoundary(
            handle: handle, segmentURL: url
        )
        switch resolution {
        case let .boundary(boundary):
            #expect(boundary == expectedBoundary)
        case .interiorCorruption:
            Issue.record("expected .boundary, got .interiorCorruption")
        }
    }

    @Test(
        "resolveBoundary over a clean prefix with trailing partial returns the prefix end (last LF), not the file size",
        .tags(.lgp14, .lgp15)
    )
    func resolveBoundaryWithTrailingPartial() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        let line1 = try Self.canonicalLine(sequence: 1)
        let line2 = try Self.canonicalLine(sequence: 2)
        let trailingPartial = Data([0x7B, 0x22]) // `{"`
        try (line1 + line2 + trailingPartial).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolution = try RecoverablePrefixScanner.resolveBoundary(
            handle: handle, segmentURL: url
        )
        switch resolution {
        case let .boundary(boundary):
            #expect(boundary == UInt64(line1.count + line2.count))
        case .interiorCorruption:
            Issue.record("expected .boundary, got .interiorCorruption")
        }
    }

    @Test(
        "resolveBoundary surfaces interior corruption with byte offset and classification",
        .tags(.lgp14, .lgp38)
    )
    func resolveBoundaryWithInteriorCorruption() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        let line = try Self.canonicalLine(sequence: 1)
        let corrupt = Data("[1,2,3]".utf8) + Data([0x0A])
        try (line + corrupt).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolution = try RecoverablePrefixScanner.resolveBoundary(
            handle: handle, segmentURL: url
        )
        switch resolution {
        case .boundary:
            Issue.record("expected .interiorCorruption, got .boundary")
        case let .interiorCorruption(byteOffset, classification):
            #expect(byteOffset == UInt64(line.count))
            #expect(classification == .nonObjectJSON)
        }
    }

    @Test(
        "Iterator reads lazily and reuses buffered accepted lines",
        .tags(.lgp14)
    )
    func iteratorReadsLazilyAndReusesBufferedLines() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        var bytes = Data()
        let lineCount = 4096
        for sequence in 1 ... lineCount {
            bytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        try bytes.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var iterator = try RecoverablePrefixScanner.iterator(
            handle: handle, segmentURL: url
        )
        // Before the first next(), no chunks have been read.
        #expect(iterator.chunkReadCountForTesting == 0)
        let first = try iterator.next()
        guard case .accepted = first else {
            Issue.record("expected first outcome .accepted")
            return
        }
        let chunksAfterFirst = iterator.chunkReadCountForTesting
        #expect(chunksAfterFirst >= 1)
        // Many lines fit in the first chunk; second next() should
        // not require additional chunk reads.
        _ = try iterator.next()
        let chunksAfterSecond = iterator.chunkReadCountForTesting
        #expect(chunksAfterFirst == chunksAfterSecond)
    }
}

extension RecoverablePrefixScannerBoundaryTests {
    @Test(
        "resolveBoundary over a large clean prefix plus interior corruption hard-stops at the corrupt line",
        .tags(.lgp14, .lgp17, .lgp27, .lgp38)
    )
    func resolveBoundaryOverLargeCleanPrefixWithInteriorCorruption() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        let totalLines = 5000
        var acceptedBytes = Data()
        for sequence in 1 ... totalLines {
            acceptedBytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        // LF-terminated non-object JSON is interior corruption, not
        // trailing partial; must hard-stop at the byte boundary
        // immediately after the last accepted LF.
        let corrupt = Data("[1,2,3]".utf8) + Data([0x0A])
        try (acceptedBytes + corrupt).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolution = try RecoverablePrefixScanner.resolveBoundary(
            handle: handle, segmentURL: url
        )
        switch resolution {
        case .boundary:
            Issue.record("expected .interiorCorruption, got .boundary")
        case let .interiorCorruption(byteOffset, classification):
            #expect(byteOffset == UInt64(acceptedBytes.count))
            #expect(classification == .nonObjectJSON)
        }
    }

    @Test(
        "resolveBoundary over a large clean prefix plus trailing partial returns the last accepted LF",
        .tags(.lgp14, .lgp15, .lgp27)
    )
    func resolveBoundaryOverLargeCleanPrefixWithTrailingPartial() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }

        let totalLines = 5000
        var acceptedBytes = Data()
        for sequence in 1 ... totalLines {
            acceptedBytes.append(try Self.canonicalLine(sequence: UInt64(sequence)))
        }
        let trailingPartial = Data([0x7B, 0x22]) // `{"`
        try (acceptedBytes + trailingPartial).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let resolution = try RecoverablePrefixScanner.resolveBoundary(
            handle: handle, segmentURL: url
        )
        switch resolution {
        case let .boundary(boundary):
            // Boundary lands at the last accepted LF, not the file
            // size; trailing partial bytes are not included.
            #expect(boundary == UInt64(acceptedBytes.count))
        case .interiorCorruption:
            Issue.record("expected .boundary, got .interiorCorruption")
        }
    }
}
