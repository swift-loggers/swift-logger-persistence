import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Export replay-identity coverage for unknown future `contentType` values.
@Suite("FileLogStore export — replay identity for unknown contentType")
struct FileLogStoreExportReplayIdentityTests {
    /// Stable opaque `contentType` outside any known profile.
    private static let unknownContentType =
        "application/vnd.unknown-future-format+xyz"

    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeUniqueDestination() throws -> (destination: URL, parent: URL) {
        let parent = uniqueDirectory()
        try makeDirectory(parent)
        return (parent.appendingPathComponent("export.ndjson"), parent)
    }
}

// MARK: - .never rotation

extension FileLogStoreExportReplayIdentityTests {
    @Test(
        "`.never` export preserves unknown-contentType accepted bytes byte-for-byte",
        .tags(.lgp8, .lgp27, .lgp30, .lgp31, .lgp32)
    )
    func neverExportPreservesUnknownContentTypeBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )

        let payload = Data([0x01, 0x02, 0x03])
        var expected = Data()
        for sequence: UInt64 in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence,
                payload: payload,
                contentType: Self.unknownContentType
            )
            try await store.append(envelope)
            expected.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        try await store.flush()

        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        try await store.exportLogs(to: destination)

        let exportBytes = try Data(contentsOf: destination)
        // Exact canonical bytes prove unknown `contentType` remains opaque.
        #expect(exportBytes == expected)
    }
}

// MARK: - .bySize rotation across segment boundaries

extension FileLogStoreExportReplayIdentityTests {
    @Test(
        "`.bySize` export preserves unknown-contentType accepted bytes across segment boundaries",
        .tags(.lgp8, .lgp27, .lgp30, .lgp31, .lgp32)
    )
    func bySizeExportPreservesUnknownContentTypeBytesAcrossSegments() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: rotation)
        )

        // Rotation-sized payloads force one envelope per segment.
        var expected = Data()
        for sequence: UInt64 in 1 ... 4 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence,
                payload: FileLogStoreTestSupport.rotationPayload(),
                contentType: Self.unknownContentType
            )
            try await store.append(envelope)
            expected.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        try await store.flush()

        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        try await store.exportLogs(to: destination)

        let exportBytes = try Data(contentsOf: destination)
        // Export must concatenate canonical accepted bytes across segments.
        #expect(exportBytes == expected)
    }
}
