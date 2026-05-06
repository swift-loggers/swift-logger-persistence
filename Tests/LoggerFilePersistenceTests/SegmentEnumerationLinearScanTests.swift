import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for large rotated directories, direct unrotated
/// lookup, and symlink-safe rotated discovery.
@Suite("SegmentEnumeration large-directory and metadata lookup")
struct SegmentEnumerationLinearScanTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
}

extension SegmentEnumerationLinearScanTests {
    @Test(
        "highestRotatedSegmentSequence returns maximum over large directory",
        .tags(.lgp6, .lgp39)
    )
    func highestSequenceOverLargeRotatedDirectory() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Large, non-contiguous numeric sequences must still resolve to the maximum.
        let sequences: [UInt64] = (1 ... 1000).map { UInt64($0 * 7) }
        for sequence in sequences {
            let url = SegmentEnumeration.rotatedSegmentURL(
                in: directory, sequence: sequence, minimumWidth: 6
            )
            try Data().write(to: url)
        }

        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == sequences.max())
    }

    @Test(
        "highestRotatedSegmentSequence fails closed on duplicate numeric sequence",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func highestSequenceFailsClosedOnDuplicate() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try Data().write(to: directory.appendingPathComponent("log.1.ndjson"))
        try Data().write(to: directory.appendingPathComponent("log.000001.ndjson"))

        do {
            _ = try SegmentEnumeration.highestRotatedSegmentSequence(
                in: directory, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                // Duplicate diagnostics report the lexically-larger spelling.
                #expect(url.lastPathComponent == "log.1.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "highestRotatedSegmentSequence returns nil for a directory with no rotated segments",
        .tags(.lgp6)
    )
    func highestSequenceEmptyDirectory() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == nil)
    }

    @Test(
        "highestRotatedSegmentSequence matches enumerate diagnostic URL",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func highestSequenceMatchesEnumerateForThreeSpellings() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Three regular files, all parsing to sequence 1, in
        // distinct lex orders so the readdir order cannot
        // accidentally match the sorted order.
        try Data().write(to: directory.appendingPathComponent("log.1.ndjson"))
        try Data().write(to: directory.appendingPathComponent("log.000001.ndjson"))
        try Data().write(to: directory.appendingPathComponent("log.0000001.ndjson"))

        var enumerateURL: URL?
        do {
            _ = try SegmentEnumeration.enumerateRotatedSegments(
                in: directory, fileManager: FileManager.default
            )
            Issue.record("expected enumerateRotatedSegments to throw")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                enumerateURL = url
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }

        var highestURL: URL?
        do {
            _ = try SegmentEnumeration.highestRotatedSegmentSequence(
                in: directory, fileManager: FileManager.default
            )
            Issue.record("expected highestRotatedSegmentSequence to throw")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                highestURL = url
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }

        // Both discovery paths must report the same deterministic duplicate URL.
        #expect(enumerateURL?.lastPathComponent == "log.000001.ndjson")
        #expect(highestURL == enumerateURL)
    }
}

extension SegmentEnumerationLinearScanTests {
    @Test(
        "unrotatedSegmentURLIfRegular returns nil when log.ndjson is absent, even with sibling files present",
        .tags(.lgp14)
    )
    func unrotatedAbsentReturnsNilDespiteSiblings() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        // Sibling rotated files must not make the unrotated segment appear present.
        for sequence in 1 ... 64 {
            let url = directory.appendingPathComponent(
                String(format: "log.%06d.ndjson", sequence)
            )
            try Data().write(to: url)
        }
        let result = try SegmentEnumeration.unrotatedSegmentURLIfRegular(
            in: directory, fileManager: FileManager.default
        )
        #expect(result == nil)
    }

    @Test(
        "unrotatedSegmentURLIfRegular returns nil when the parent directory itself does not exist",
        .tags(.lgp14)
    )
    func unrotatedAbsentParentReturnsNil() throws {
        let directory = Self.uniqueDirectory()
        // Missing parent directory means no unrotated segment exists.
        let result = try SegmentEnumeration.unrotatedSegmentURLIfRegular(
            in: directory, fileManager: FileManager.default
        )
        #expect(result == nil)
    }
}

extension SegmentEnumerationLinearScanTests {
    @Test(
        "Live symlink matching `log.<digits>.ndjson` is skipped by both rotated paths",
        .tags(.lgp6, .lgp39)
    )
    func rotatedLiveSymlinkSkippedByBothPaths() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        // One genuine regular segment.
        try Data().write(to: directory.appendingPathComponent("log.000001.ndjson"))
        // Matching live symlink must be skipped, not followed.
        let target = directory.appendingPathComponent("symlink-target.bin")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("log.000002.ndjson"),
            withDestinationURL: target
        )

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [1])

        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == 1)
    }

    @Test(
        "Broken symlink matching `log.<digits>.ndjson` is skipped by both rotated paths",
        .tags(.lgp6, .lgp39)
    )
    func rotatedBrokenSymlinkSkippedByBothPaths() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        try Data().write(to: directory.appendingPathComponent("log.000001.ndjson"))
        // Matching broken symlink must be skipped.
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("log.000002.ndjson"),
            withDestinationURL: directory.appendingPathComponent("missing.bin")
        )

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [1])

        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == 1)
    }
}

extension SegmentEnumerationLinearScanTests {
    @Test(
        "Under .bySize, AcceptedLineIterator over an absent configured directory yields empty output",
        .tags(.lgp6)
    )
    func bySizeIteratorOverAbsentDirectoryYieldsEmpty() async throws {
        let directory = Self.uniqueDirectory()
            .appendingPathComponent("does-not-exist")
        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        var collected: [Data] = []
        for try await bytes in stream {
            collected.append(bytes)
        }
        #expect(collected.isEmpty)
    }
}
