import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Byte-stable export coverage focused on `.bySize` topologies:
/// rotated middle-segment corruption, multi-segment trailing
/// partial, and empty topology.
@Suite("FileLogStore byte-stable export — rotated topology")
struct FileLogStoreExportRotatedTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeBySizeStore(
        directory: URL
    ) throws -> FileLogStore {
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        return FileLogStore(
            configuration: .init(directory: directory, rotation: policy)
        )
    }

    /// Returns a unique export destination URL and its owning
    /// parent directory. The caller owns the parent's removal.
    private static func makeUniqueDestination() throws -> (destination: URL, parent: URL) {
        let parent = uniqueDirectory()
        try makeDirectory(parent)
        return (parent.appendingPathComponent("export.ndjson"), parent)
    }

    /// Appends `count` accepted lines and returns their
    /// accepted-byte concatenation in append order.
    private static func appendRotationLines(
        store: FileLogStore, count: Int
    ) async throws -> Data {
        var concat = Data()
        for sequence in 1 ... count {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
            concat.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        return concat
    }

    /// Verifies that export discovery observes contiguous
    /// rotated-segment sequences without gaps.
    private static func assertRotatedTopology(
        directory: URL,
        expectedCount: UInt64
    ) {
        for sequence in 1 ... expectedCount {
            #expect(FileManager.default.fileExists(
                atPath: FileLogStoreTestSupport.rotatedSegmentURL(
                    in: directory, sequence: sequence
                ).path
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: FileLogStoreTestSupport.rotatedSegmentURL(
                in: directory, sequence: expectedCount + 1
            ).path
        ))
    }
}

// MARK: - Multi-segment interior corruption

extension FileLogStoreExportRotatedTests {
    @Test(
        "bySize export aborts at interior corruption in a middle rotated segment, leaving destination absent",
        .tags(.lgp6, .lgp8, .lgp17, .lgp32, .lgp35, .lgp37, .lgp39)
    )
    func bySizeMiddleSegmentInteriorCorruptionAborts() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeBySizeStore(directory: directory)

        _ = try await Self.appendRotationLines(store: store, count: 5)
        try await store.flush()

        // Corruption must reside in a non-terminal rotated segment.
        Self.assertRotatedTopology(directory: directory, expectedCount: 5)
        let middleSegmentURL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 2
        )

        // Append LF-terminated non-object JSON after the
        // final accepted line.
        var middleBytes = try Data(contentsOf: middleSegmentURL)
        middleBytes.append(Data("[1,2,3]\n".utf8))
        try middleBytes.write(to: middleSegmentURL)

        let (destination, parent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(parent) }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected interiorCorruption on middle segment")
        } catch {
            switch error {
            case let .interiorCorruption(seg, _, classification):
                #expect(seg == middleSegmentURL)
                #expect(classification == .nonObjectJSON)
            default:
                Issue.record("expected .interiorCorruption, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(leftovers == [])
    }
}

// MARK: - Trailing partial across rotated segments

extension FileLogStoreExportRotatedTests {
    @Test(
        "bySize export excludes a trailing partial suffix in the latest rotated segment",
        .tags(.lgp6, .lgp8, .lgp14, .lgp15, .lgp27, .lgp32, .lgp39)
    )
    func bySizeExportUsesRecoverablePrefixInLatestSegment() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeBySizeStore(directory: directory)

        let expected = try await Self.appendRotationLines(store: store, count: 4)
        try await store.flush()

        // The trailing suffix must reside in the terminal
        // rotated segment.
        Self.assertRotatedTopology(directory: directory, expectedCount: 4)

        // Append trailing partial bytes after the final accepted LF.
        let latestSegmentURL = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 4
        )
        var latestBytes = try Data(contentsOf: latestSegmentURL)
        latestBytes.append(Data([0x7B, 0x22]))
        try latestBytes.write(to: latestSegmentURL)

        let (destination, parent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(parent) }

        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        // Export preserves accepted bytes and accepted ordering
        // byte-for-byte.
        #expect(onDisk == expected)
    }
}

// MARK: - Empty bySize topology

extension FileLogStoreExportRotatedTests {
    @Test(
        "Empty bySize topology exports a 0-byte destination file",
        .tags(.lgp6, .lgp8, .lgp32, .lgp39)
    )
    func bySizeEmptyTopologyExportsZeroBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeBySizeStore(directory: directory)

        let (destination, parent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(parent) }

        try await store.exportLogs(to: destination)
        // Successful export creates an empty destination file.
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk.isEmpty)
    }
}
