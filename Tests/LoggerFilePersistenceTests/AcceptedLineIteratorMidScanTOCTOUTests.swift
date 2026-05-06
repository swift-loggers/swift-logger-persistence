import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// TOCTOU regression coverage for descriptor-relative segment opens.
@Suite("AcceptedLineIterator mid-scan TOCTOU rejection")
struct AcceptedLineIteratorMidScanTOCTOUTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
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

extension AcceptedLineIteratorMidScanTOCTOUTests {
    @Test(
        "bySize symlink swap before open fails closed",
        .tags(.lgp2, .lgp6, .lgp14, .lgp24, .lgp25)
    )
    func bySizeSymlinkSwapAfterDiscoveryFailsClosed() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let segmentURL = directory.appendingPathComponent("log.000001.ndjson")
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        try acceptedLine.write(to: segmentURL)

        // Attacker-controlled target must never be read.
        let attackerHome = Self.uniqueDirectory()
        try Self.makeDirectory(attackerHome)
        defer { FileLogStoreTestSupport.remove(attackerHome) }
        let attackerTarget = attackerHome.appendingPathComponent("attacker.bin")
        let attackerBytes = Data("ATTACKER\n".utf8)
        try attackerBytes.write(to: attackerTarget)

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        let iterator = stream.makeAsyncIterator()

        // Race the swap deterministically against `openat`.
        iterator._onSegmentsDiscoveredForTesting = {
            try FileManager.default.removeItem(at: segmentURL)
            try FileManager.default.createSymbolicLink(
                at: segmentURL, withDestinationURL: attackerTarget
            )
        }

        do {
            _ = try await iterator.next()
            Issue.record("expected operationFailed(.openSegment)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openSegment)
                #expect(url.lastPathComponent == "log.000001.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }

        // Iterator terminates after the failure; no further pulls.
        let afterFailure = try await iterator.next()
        #expect(afterFailure == nil)

        let onTarget = try Data(contentsOf: attackerTarget)
        #expect(onTarget == attackerBytes)
    }

    @Test(
        "never symlink swap before open fails closed",
        .tags(.lgp2, .lgp14, .lgp24, .lgp25)
    )
    func neverSymlinkSwapAfterDiscoveryFailsClosed() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let segmentURL = directory.appendingPathComponent("log.ndjson")
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        try acceptedLine.write(to: segmentURL)

        let attackerHome = Self.uniqueDirectory()
        try Self.makeDirectory(attackerHome)
        defer { FileLogStoreTestSupport.remove(attackerHome) }
        let attackerTarget = attackerHome.appendingPathComponent("attacker.bin")
        let attackerBytes = Data("ATTACKER\n".utf8)
        try attackerBytes.write(to: attackerTarget)

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        let iterator = stream.makeAsyncIterator()

        iterator._onSegmentsDiscoveredForTesting = {
            try FileManager.default.removeItem(at: segmentURL)
            try FileManager.default.createSymbolicLink(
                at: segmentURL, withDestinationURL: attackerTarget
            )
        }

        do {
            _ = try await iterator.next()
            Issue.record("expected operationFailed(.openSegment)")
        } catch let error as InternalReadError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openSegment)
                #expect(url.lastPathComponent == "log.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }

        let afterFailure = try await iterator.next()
        #expect(afterFailure == nil)

        let onTarget = try Data(contentsOf: attackerTarget)
        #expect(onTarget == attackerBytes)
    }

    @Test(
        "root path swap after descriptor open does not redirect reads",
        .tags(.lgp2, .lgp6, .lgp14, .lgp24, .lgp25)
    )
    func rootSwapAfterDescriptorOpenDoesNotRedirectReads() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        let renamedDirectory = directory
            .deletingLastPathComponent()
            .appendingPathComponent("renamed-" + UUID().uuidString)
        defer {
            FileLogStoreTestSupport.remove(directory)
            FileLogStoreTestSupport.remove(renamedDirectory)
        }

        let segmentURL = directory.appendingPathComponent("log.000001.ndjson")
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        try acceptedLine.write(to: segmentURL)

        // Attacker payload would surface only via path-resolved reads.
        let attackerRoot = Self.uniqueDirectory()
        try Self.makeDirectory(attackerRoot)
        defer { FileLogStoreTestSupport.remove(attackerRoot) }
        let attackerSegment = attackerRoot.appendingPathComponent("log.000001.ndjson")
        let attackerLine = try Self.canonicalLine(sequence: 99)
        try attackerLine.write(to: attackerSegment)

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        let iterator = stream.makeAsyncIterator()

        // Rename keeps the original inode (the held descriptor still
        // references it); the symlink at the freed path is never
        // consulted by `openat(rootFD, ...)`.
        iterator._onSegmentsDiscoveredForTesting = {
            try FileManager.default.moveItem(at: directory, to: renamedDirectory)
            try FileManager.default.createSymbolicLink(
                at: directory, withDestinationURL: attackerRoot
            )
        }

        let first = try await iterator.next()
        #expect(first == acceptedLine)

        // Stream ends after the only segment; the attacker payload
        // is never visible on a subsequent pull.
        let second = try await iterator.next()
        #expect(second == nil)
    }

    @Test(
        "discovery hook throw propagates and terminates the iterator",
        .tags(.lgp14, .lgp24, .lgp25)
    )
    func discoveryHookThrowPropagatesAndTerminates() async throws {
        struct SentinelError: Error, Equatable {}

        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        try Self.canonicalLine(sequence: 1).write(
            to: directory.appendingPathComponent("log.000001.ndjson")
        )

        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let iterator = AcceptedLineIterator
            .acceptedLines(configuration: configuration)
            .makeAsyncIterator()
        iterator._onSegmentsDiscoveredForTesting = {
            throw SentinelError()
        }

        do {
            _ = try await iterator.next()
            Issue.record("expected hook to throw")
        } catch is SentinelError {
            // Expected; iterator must now be terminal.
        }

        // Subsequent pull confirms the iterator is terminal.
        let after = try await iterator.next()
        #expect(after == nil)
    }
}
