import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// `AcceptedLineIterator` configuration-driven, byte-stable
/// recovery iteration.
@Suite("AcceptedLineIterator accepted-line iteration")
struct AcceptedLineIteratorTests {
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

    private static func canonicalLine(
        sequence: UInt64 = 1,
        contentType: String = "application/vnd.test.v1+json"
    ) throws -> Data {
        let envelope = try PersistentLogEnvelope(
            id: FileLogStoreTestSupport.baselineId,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: contentType,
            hints: [:],
            payload: Data([0x01, 0x02, 0x03])
        )
        return try CanonicalEnvelopeLineEncoder().encode(envelope)
    }

    private static func collect(
        _ sequence: AcceptedLineSequence
    ) async throws -> [Data] {
        var output: [Data] = []
        for try await bytes in sequence {
            output.append(bytes)
        }
        return output
    }
}

extension AcceptedLineIteratorTests {
    @Test(
        "Under .never, the iterator reads only the unrotated log.ndjson segment in file byte order",
        .tags(.lgp14, .lgp27)
    )
    func neverPolicyReadsSingleUnrotatedSegment() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let line1 = try Self.canonicalLine(sequence: 1)
        let line2 = try Self.canonicalLine(sequence: 2)
        try Self.write(
            line1 + line2,
            to: directory.appendingPathComponent("log.ndjson")
        )
        // A rotated-pattern file in the same directory must NOT be
        // pulled in under .never.
        try Self.write(
            try Self.canonicalLine(sequence: 99),
            to: directory.appendingPathComponent("log.000001.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [line1, line2])
    }

    @Test(
        "Under .never, an absent log.ndjson yields an empty stream",
        .tags(.lgp14)
    )
    func neverPolicyAbsentSegmentYieldsEmptyStream() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines.isEmpty)
    }

    @Test(
        "Under .never, a directory at log.ndjson surfaces .operationFailed(.enumerateSegments)",
        .tags(.lgp2, .lgp6)
    )
    func neverPolicyDirectoryAtSegmentPathSurfacesError() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("log.ndjson"),
            withIntermediateDirectories: true
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        do {
            _ = try await Self.collect(stream)
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url.lastPathComponent == "log.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "Under .bySize, rotated segments are read in numeric segment-index ascending order, not lexical filename order",
        .tags(.lgp6, .lgp14, .lgp27)
    )
    func bySizePolicyReadsSegmentsInNumericAscendingOrder() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Cross padding widths so numeric ordering is distinguishable
        // from lexical ordering.
        let lineA = try Self.canonicalLine(sequence: 1)
        let lineB = try Self.canonicalLine(sequence: 2)
        let lineC = try Self.canonicalLine(sequence: 3)
        try Self.write(lineA, to: directory.appendingPathComponent("log.000002.ndjson"))
        try Self.write(lineB, to: directory.appendingPathComponent("log.10.ndjson"))
        try Self.write(lineC, to: directory.appendingPathComponent("log.000099.ndjson"))

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        // Numeric ascending: 2, 10, 99 -> lineA, lineB, lineC.
        #expect(lines == [lineA, lineB, lineC])
    }

    @Test(
        "Under .bySize, an unrotated log.ndjson is NOT pulled in",
        .tags(.lgp6)
    )
    func bySizePolicyDoesNotMixUnrotatedSegment() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let rotated = try Self.canonicalLine(sequence: 1)
        try Self.write(rotated, to: directory.appendingPathComponent("log.000001.ndjson"))
        try Self.write(
            try Self.canonicalLine(sequence: 99),
            to: directory.appendingPathComponent("log.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [rotated])
    }

    @Test(
        "Multi-segment iteration preserves accepted bytes byte-for-byte across the segment boundary",
        .tags(.lgp14, .lgp27)
    )
    func multiSegmentBytesPreservedExactly() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let s1Line1 = try Self.canonicalLine(sequence: 1)
        let s1Line2 = try Self.canonicalLine(sequence: 2)
        let s2Line1 = try Self.canonicalLine(sequence: 3)
        try Self.write(
            s1Line1 + s1Line2,
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        try Self.write(
            s2Line1,
            to: directory.appendingPathComponent("log.000002.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [s1Line1, s1Line2, s2Line1])
    }

    @Test(
        "Trailing partial bytes in the last segment are excluded from the iterator's output",
        .tags(.lgp14, .lgp15, .lgp16)
    )
    func trailingPartialInLastSegmentExcluded() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let line = try Self.canonicalLine()
        try Self.write(
            line + Data([0x7B, 0x22]),
            to: directory.appendingPathComponent("log.000001.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [line])
    }

    @Test(
        "Interior corruption in an earlier segment hard-stops the iteration; later segments are not visible",
        .tags(.lgp14, .lgp17, .lgp36, .lgp37)
    )
    func interiorCorruptionInEarlierSegmentHardStops() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let acceptedFirst = try Self.canonicalLine(sequence: 1)
        let corruptLine = Data("[1,2,3]".utf8) + Data([0x0A])
        try Self.write(
            acceptedFirst + corruptLine,
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        try Self.write(
            try Self.canonicalLine(sequence: 99),
            to: directory.appendingPathComponent("log.000002.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )

        var collected: [Data] = []
        do {
            for try await bytes in stream {
                collected.append(bytes)
            }
            Issue.record("expected interiorCorruption")
        } catch let error as InternalReadError {
            // The accepted prefix is yielded, corruption hard-stops
            // iteration, and the later segment is never visible.
            #expect(collected == [acceptedFirst])
            switch error {
            case let .interiorCorruption(_, _, classification):
                #expect(classification == .nonObjectJSON)
            case .operationFailed:
                Issue.record("expected interiorCorruption, got operationFailed")
            }
        }
    }

    @Test(
        "An accepted line with an unknown contentType is yielded byte-for-byte",
        .tags(.lgp27, .lgp30)
    )
    func unknownContentTypeYieldedVerbatim() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let line = try Self.canonicalLine(
            contentType: "application/vnd.unknown-future-format+xyz"
        )
        try Self.write(
            line, to: directory.appendingPathComponent("log.000001.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [line])
    }

    @Test(
        "Subdirectories matching the rotated-segment pattern are skipped via the regular-file filter",
        .tags(.lgp6)
    )
    func bySizePolicySkipsDirectoryRotatedEntries() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("log.000001.ndjson"),
            withIntermediateDirectories: true
        )
        let line = try Self.canonicalLine(sequence: 5)
        try Self.write(
            line, to: directory.appendingPathComponent("log.000005.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [line])
    }

    @Test(
        "Symlinks matching the rotated-segment pattern are skipped via the regular-file filter",
        .tags(.lgp6)
    )
    func bySizePolicySkipsSymlinkRotatedEntries() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // A symlink to a regular file must not be admitted by
        // enumeration; only direct regular files are segment
        // candidates.
        let target = directory.appendingPathComponent("regular-target.bin")
        try Self.write(Data(), to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("log.000001.ndjson"),
            withDestinationURL: target
        )
        let line = try Self.canonicalLine(sequence: 5)
        try Self.write(
            line, to: directory.appendingPathComponent("log.000005.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let lines = try await Self.collect(
            AcceptedLineIterator.acceptedLines(
                configuration: configuration
            )
        )
        #expect(lines == [line])
    }

    @Test(
        "Under .never, a symlink at log.ndjson surfaces .operationFailed(.enumerateSegments)",
        .tags(.lgp2, .lgp6)
    )
    func neverPolicySymlinkAtSegmentPathSurfacesError() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let target = directory.appendingPathComponent("symlink-target.bin")
        try Self.write(Data(), to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("log.ndjson"),
            withDestinationURL: target
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        do {
            _ = try await Self.collect(stream)
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url.lastPathComponent == "log.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "Interior corruption in a later segment yields the earlier segment's accepted line, then hard-stops",
        .tags(.lgp14, .lgp17, .lgp36, .lgp37)
    )
    func interiorCorruptionInLaterSegmentYieldsEarlierAcceptedThenHardStops() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let acceptedFirst = try Self.canonicalLine(sequence: 1)
        try Self.write(
            acceptedFirst,
            to: directory.appendingPathComponent("log.000001.ndjson")
        )
        // Segment 2 is interior corruption; segment 1 is fully clean.
        try Self.write(
            Data("[1,2,3]".utf8) + Data([0x0A]),
            to: directory.appendingPathComponent("log.000002.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )

        var collected: [Data] = []
        do {
            for try await bytes in stream {
                collected.append(bytes)
            }
            Issue.record("expected interiorCorruption")
        } catch let error as InternalReadError {
            #expect(collected == [acceptedFirst])
            switch error {
            case let .interiorCorruption(_, _, classification):
                #expect(classification == .nonObjectJSON)
            case .operationFailed:
                Issue.record("expected interiorCorruption, got operationFailed")
            }
        }
    }

    @Test(
        "Under .bySize, duplicate numeric segment index fails the stream without yielding any line",
        .tags(.lgp2, .lgp6)
    )
    func bySizePolicyDuplicateNumericIndexFailsWithoutPartialOutput() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Two regular files mapping to the same numeric segment index
        // are an ambiguous topology. The iterator must fail without
        // yielding any partial output as success.
        let line = try Self.canonicalLine(sequence: 1)
        try Self.write(line, to: directory.appendingPathComponent("log.1.ndjson"))
        try Self.write(line, to: directory.appendingPathComponent("log.000001.ndjson"))

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        var collected: [Data] = []
        do {
            for try await bytes in stream {
                collected.append(bytes)
            }
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch let error as InternalReadError {
            #expect(collected.isEmpty)
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .enumerateSegments)
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }
}
