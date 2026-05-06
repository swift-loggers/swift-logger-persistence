import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Memory-bound conformance: the scanner must classify or stop
/// without holding the entire segment in memory.
extension RecoverablePrefixScannerTests {
    /// 3 MiB exercises the over-cap path; the encoded-line cap is 2 MiB.
    private static var overCapByteCount: Int { 3 * 1_048_576 }

    @Test(
        "A multi-megabyte segment with no LF reports .trailingPartial(byteOffset: 0) without buffering the whole tail",
        .tags(.lgp14, .lgp15)
    )
    func hugeNoLFSegmentTrailingPartialWithoutFullBuffer() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let bytes = Data(repeating: 0x41, count: Self.overCapByteCount)
        try Self.writeSegment(bytes, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [.trailingPartial(byteOffset: 0)])
    }

    @Test(
        "An accepted line followed by a multi-megabyte no-LF tail yields accepted then trailingPartial at the boundary",
        .tags(.lgp14, .lgp15)
    )
    func acceptedLinePlusHugeNoLFTail() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let line = try Self.canonicalLine()
        let tail = Data(repeating: 0x41, count: Self.overCapByteCount)
        try Self.writeSegment(line + tail, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: line),
            .trailingPartial(byteOffset: UInt64(line.count))
        ])
    }

    @Test(
        "An over-cap LF-terminated line hard-stops as terminal .corrupt(.invalidEnvelope) at line start",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func overCapLFTerminatedLineHardStopsAsInvalidEnvelope() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        // 3 MiB of `A` + LF; total > 2 MiB encoded-line cap.
        var bytes = Data(repeating: 0x41, count: Self.overCapByteCount)
        bytes.append(0x0A)
        try Self.writeSegment(bytes, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [
            .corrupt(byteOffset: 0, classification: .invalidEnvelope)
        ])
    }

    @Test(
        "An accepted prefix followed by an over-cap LF-terminated line hard-stops with no later accepted line visible",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func acceptedPrefixThenOverCapLineHardStops() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let firstLine = try Self.canonicalLine(sequence: 1)
        var overCapLine = Data(repeating: 0x41, count: Self.overCapByteCount)
        overCapLine.append(0x0A)
        let laterAccepted = try Self.canonicalLine(sequence: 2)
        try Self.writeSegment(firstLine + overCapLine + laterAccepted, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: firstLine),
            .corrupt(
                byteOffset: UInt64(firstLine.count),
                classification: .invalidEnvelope
            )
        ])
    }
}
