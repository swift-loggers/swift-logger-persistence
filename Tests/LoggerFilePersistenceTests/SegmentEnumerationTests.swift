import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// `SegmentEnumeration` filename-driven discovery contract.
@Suite("SegmentEnumeration rotated-segment discovery")
struct SegmentEnumerationTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func touchFile(at url: URL, contents: Data = Data()) throws {
        try contents.write(to: url)
    }

    private static func segmentName(_ digits: String) -> String {
        "log.\(digits).ndjson"
    }
}

extension SegmentEnumerationTests {
    @Test(
        "Rotated segments are returned in numeric segment-index ascending order, not lexical filename order",
        .tags(.lgp6)
    )
    func segmentsReturnedInNumericAscendingOrder() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Mixed padding makes lexical ordering differ from numeric ordering.
        let segments = [
            Self.segmentName("000010"),
            Self.segmentName("2"),
            Self.segmentName("000003"),
            Self.segmentName("1"),
            Self.segmentName("0000007")
        ]
        for name in segments {
            try Self.touchFile(at: directory.appendingPathComponent(name))
        }

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        let sequences = enumerated.map(\.sequence)
        #expect(sequences == [1, 2, 3, 7, 10])
    }

    @Test(
        "highestRotatedSegmentSequence returns the largest numeric segment index, regardless of zero-padding width",
        .tags(.lgp6)
    )
    func highestRotatedSegmentSequenceIsPaddingIndependent() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("0000099")))
        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("100")))
        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("000050")))

        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == 100)
    }

    @Test(
        "highestRotatedSegmentSequence returns nil when no rotated segments are present",
        .tags(.lgp6)
    )
    func highestRotatedSegmentSequenceIsNilWhenNoSegments() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Unrelated regular file under .never policy.
        try Self.touchFile(at: directory.appendingPathComponent("log.ndjson"))

        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: directory, fileManager: FileManager.default
        )
        #expect(highest == nil)
    }

    @Test(
        "Names that don't match log.<positive-decimal>.ndjson are skipped",
        .tags(.lgp6)
    )
    func skipsNamesThatDoNotMatchPattern() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let invalid = [
            "log.000000.ndjson", // sequence 0 reserved
            "log..ndjson", // empty middle
            "log.abc.ndjson", // non-digit
            "log.10a.ndjson", // mixed digits
            "log.1.ndjson.bak", // wrong suffix
            "prefix.log.1.ndjson", // wrong prefix in path component
            "log.ndjson", // .never filename
            "LOG.000001.NDJSON" // wrong case
        ]
        for name in invalid {
            try Self.touchFile(at: directory.appendingPathComponent(name))
        }
        // Add one valid sentinel so we can distinguish "skipped"
        // from "directory empty".
        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("000005")))

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [5])
    }

    @Test(
        "Directory entries matching the segment pattern are skipped via the regular-file filter",
        .tags(.lgp6)
    )
    func skipsDirectoryEntryEvenWhenNameMatches() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let directoryEntry = directory.appendingPathComponent(Self.segmentName("000004"))
        try FileManager.default.createDirectory(
            at: directoryEntry, withIntermediateDirectories: true
        )
        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("000005")))

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [5])
    }

    @Test(
        "Two regular files mapping to the same numeric segment index fail enumeration",
        .tags(.lgp2, .lgp6)
    )
    func duplicateNumericSegmentIndexFailsEnumeration() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Both `log.1.ndjson` and `log.000001.ndjson` parse to
        // sequence 1. Enumeration must not pick a winner.
        try Self.touchFile(at: directory.appendingPathComponent("log.1.ndjson"))
        try Self.touchFile(at: directory.appendingPathComponent("log.000001.ndjson"))

        do {
            _ = try SegmentEnumeration.enumerateRotatedSegments(
                in: directory, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                // Deterministic: sorted by (sequence, lastPathComponent),
                // duplicate detector reports the lexically-larger filename.
                #expect(url.lastPathComponent == "log.1.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "highestRotatedSegmentSequence inherits duplicate-detection failure",
        .tags(.lgp2, .lgp6)
    )
    func duplicateNumericSegmentIndexFailsHighestSequence() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        try Self.touchFile(at: directory.appendingPathComponent("log.1.ndjson"))
        try Self.touchFile(at: directory.appendingPathComponent("log.000001.ndjson"))

        do {
            _ = try SegmentEnumeration.highestRotatedSegmentSequence(
                in: directory, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url.lastPathComponent == "log.1.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "Non-regular duplicate (directory) is filtered out before duplicate detection",
        .tags(.lgp6)
    )
    func nonRegularDuplicateDoesNotTriggerFailure() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Non-regular duplicate must not shadow the regular segment.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("log.1.ndjson"),
            withIntermediateDirectories: true
        )
        try Self.touchFile(at: directory.appendingPathComponent("log.000001.ndjson"))

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [1])
        #expect(enumerated.first?.url.lastPathComponent == "log.000001.ndjson")
    }

    @Test(
        "Symlink entries matching the segment pattern are skipped via the regular-file filter",
        .tags(.lgp6)
    )
    func skipsSymlinkEntryEvenWhenNameMatches() throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Symlink candidates must be skipped, not followed.
        let regularTarget = directory.appendingPathComponent("regular-target.bin")
        try Self.touchFile(at: regularTarget)
        let symlinkEntry = directory.appendingPathComponent(Self.segmentName("000004"))
        try FileManager.default.createSymbolicLink(
            at: symlinkEntry,
            withDestinationURL: regularTarget
        )
        try Self.touchFile(at: directory.appendingPathComponent(Self.segmentName("000005")))

        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        #expect(enumerated.map(\.sequence) == [5])
    }
}

extension SegmentEnumerationTests {
    @Test(
        "Absent configured directory is observed as an empty store",
        .tags(.lgp6)
    )
    func absentConfiguredDirectoryReturnsEmpty() throws {
        let missing = Self.uniqueDirectory()
            .appendingPathComponent("does-not-exist")
        let enumerated = try SegmentEnumeration.enumerateRotatedSegments(
            in: missing, fileManager: FileManager.default
        )
        #expect(enumerated.isEmpty)
        let highest = try SegmentEnumeration.highestRotatedSegmentSequence(
            in: missing, fileManager: FileManager.default
        )
        #expect(highest == nil)
    }
}

extension SegmentEnumerationTests {
    @Test(
        "parsedSequence accepts log.<positive-decimal>.ndjson",
        .tags(.lgp6)
    )
    func parsedSequenceAcceptsPositiveDecimal() {
        #expect(SegmentEnumeration.parsedSequence(in: "log.1.ndjson") == 1)
        #expect(SegmentEnumeration.parsedSequence(in: "log.000001.ndjson") == 1)
        #expect(SegmentEnumeration.parsedSequence(in: "log.18446744073709551615.ndjson") == UInt64.max)
    }

    @Test(
        "parsedSequence rejects sequence 0 (reserved)",
        .tags(.lgp6)
    )
    func parsedSequenceRejectsZero() {
        #expect(SegmentEnumeration.parsedSequence(in: "log.0.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log.000000.ndjson") == nil)
    }

    @Test(
        "parsedSequence rejects sequence overflowing UInt64",
        .tags(.lgp6)
    )
    func parsedSequenceRejectsOverflow() {
        #expect(SegmentEnumeration.parsedSequence(in: "log.18446744073709551616.ndjson") == nil)
    }

    @Test(
        "parsedSequence rejects names with non-digit segment-index characters",
        .tags(.lgp6)
    )
    func parsedSequenceRejectsNonDigit() {
        #expect(SegmentEnumeration.parsedSequence(in: "log.a.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log.1a.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log. 1.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log.+1.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log.-1.ndjson") == nil)
    }

    @Test(
        "parsedSequence rejects empty middle segment",
        .tags(.lgp6)
    )
    func parsedSequenceRejectsEmptyMiddle() {
        #expect(SegmentEnumeration.parsedSequence(in: "log..ndjson") == nil)
    }

    @Test(
        "parsedSequence rejects mismatched prefix/suffix",
        .tags(.lgp6)
    )
    func parsedSequenceRejectsMismatchedPrefixSuffix() {
        #expect(SegmentEnumeration.parsedSequence(in: "log.1.ndjson.bak") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "X.log.1.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "log.ndjson") == nil)
        #expect(SegmentEnumeration.parsedSequence(in: "LOG.000001.NDJSON") == nil)
    }
}
