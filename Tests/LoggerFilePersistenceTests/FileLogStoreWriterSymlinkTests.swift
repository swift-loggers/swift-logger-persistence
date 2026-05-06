import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Writer-side regression coverage for symlink-safe segment open.
@Suite("FileLogStore writer rejects symlink at segment path")
struct FileLogStoreWriterSymlinkTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func canonicalEnvelope(sequence: UInt64) throws -> PersistentLogEnvelope {
        try PersistentLogEnvelope(
            id: FileLogStoreTestSupport.baselineId,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.test.v1+json",
            hints: [:],
            payload: Data([0x01, 0x02, 0x03])
        )
    }
}

extension FileLogStoreWriterSymlinkTests {
    @Test(
        "Under .never, append must fail closed when log.ndjson is a live symlink to a writable file",
        .tags(.lgp2, .lgp24, .lgp25)
    )
    func neverPolicyLiveSymlinkAtSegmentPathRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Append must not write through the symlink target.
        let target = directory.appendingPathComponent("symlink-target.bin")
        try Data().write(to: target)
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        try FileManager.default.createSymbolicLink(
            at: segmentURL, withDestinationURL: target
        )

        let store = FileLogStore(configuration: .init(directory: directory))
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected operationFailed(.openWritableSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                #expect(url.lastPathComponent == "log.ndjson")
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
        // Symlink target must still be empty; no admit went through.
        let onTarget = try Data(contentsOf: target)
        #expect(onTarget.isEmpty)
    }

    @Test(
        "Under .never, append must fail closed when log.ndjson is a broken symlink",
        .tags(.lgp2, .lgp24, .lgp25)
    )
    func neverPolicyBrokenSymlinkAtSegmentPathRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        try FileManager.default.createSymbolicLink(
            at: segmentURL,
            withDestinationURL: directory.appendingPathComponent("missing.bin")
        )

        let store = FileLogStore(configuration: .init(directory: directory))
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected operationFailed(.openWritableSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                #expect(url.lastPathComponent == "log.ndjson")
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
    }

    @Test(
        "Under .bySize, append must fail closed when the rotated segment path is a live symlink to a writable file",
        .tags(.lgp2, .lgp6, .lgp24, .lgp25)
    )
    func rotatedLiveSymlinkAtSegmentPathRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let target = directory.appendingPathComponent("symlink-target.bin")
        try Data().write(to: target)
        // Append must not write through the rotated symlink target.
        let symlinkURL = SegmentEnumeration.rotatedSegmentURL(
            in: directory, sequence: 1, minimumWidth: 6
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL, withDestinationURL: target
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let store = FileLogStore(configuration: configuration)
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected operationFailed(.openWritableSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                #expect(url.lastPathComponent == symlinkURL.lastPathComponent)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
        let onTarget = try Data(contentsOf: target)
        #expect(onTarget.isEmpty)
    }

    @Test(
        "Under .bySize, append must fail closed when the rotated segment path is a broken symlink",
        .tags(.lgp2, .lgp6, .lgp24, .lgp25)
    )
    func rotatedBrokenSymlinkAtSegmentPathRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let symlinkURL = SegmentEnumeration.rotatedSegmentURL(
            in: directory, sequence: 1, minimumWidth: 6
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: directory.appendingPathComponent("missing.bin")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let store = FileLogStore(configuration: configuration)
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected operationFailed(.openWritableSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                #expect(url.lastPathComponent == symlinkURL.lastPathComponent)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
    }
}
