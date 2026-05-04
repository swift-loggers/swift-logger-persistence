import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for symlinked configured root rejection.
@Suite("Symlinked configured root rejection")
struct SymlinkedConfiguredRootTests {
    private struct SymlinkedRoot {
        let parent: URL
        let realDir: URL
        let symlinkedRoot: URL
    }

    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Builds `parent/realDir` (real directory) and a symlink
    /// `parent/symlinkedRoot` pointing at it. Caller cleans up
    /// `parent`.
    private static func makeSymlinkedRoot() throws -> SymlinkedRoot {
        let parent = Self.uniqueDirectory()
        try Self.makeDirectory(parent)
        let realDir = parent.appendingPathComponent("realDir")
        try Self.makeDirectory(realDir)
        let symlinkedRoot = parent.appendingPathComponent("symlinkedRoot")
        try FileManager.default.createSymbolicLink(
            at: symlinkedRoot, withDestinationURL: realDir
        )
        return SymlinkedRoot(parent: parent, realDir: realDir, symlinkedRoot: symlinkedRoot)
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

    private static func assertEnumerateFailedAtRoot(
        _ error: InternalReadError,
        expectedURL: URL
    ) {
        switch error {
        case let .operationFailed(operation, url, _):
            #expect(operation == .enumerateSegments)
            #expect(url == expectedURL)
        case .interiorCorruption:
            Issue.record("expected operationFailed, got interiorCorruption")
        }
    }

    /// Asserts the symlink target directory is byte-identical to its
    /// pre-append state. The contract is stronger than "expected
    /// segment filename absent": the target must not gain any entry
    /// at all.
    private static func assertTargetDirectoryUnmodified(_ realDir: URL) throws {
        let targetEntries = try FileManager.default.contentsOfDirectory(
            atPath: realDir.path
        )
        #expect(targetEntries.isEmpty)
    }
}

// MARK: - Read-side: direct SegmentEnumeration

extension SymlinkedConfiguredRootTests {
    @Test(
        "enumerateRotatedSegments fails closed on symlinked root",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func enumerateRotatedSegmentsRejectsSymlinkedRoot() throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }
        try Data().write(to: layout.realDir.appendingPathComponent("log.000001.ndjson"))

        do {
            _ = try SegmentEnumeration.enumerateRotatedSegments(
                in: layout.symlinkedRoot, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            Self.assertEnumerateFailedAtRoot(error, expectedURL: layout.symlinkedRoot)
        }
    }

    @Test(
        "highestRotatedSegmentSequence fails closed on symlinked root",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func highestRotatedSegmentSequenceRejectsSymlinkedRoot() throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }
        try Data().write(to: layout.realDir.appendingPathComponent("log.000001.ndjson"))

        do {
            _ = try SegmentEnumeration.highestRotatedSegmentSequence(
                in: layout.symlinkedRoot, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            Self.assertEnumerateFailedAtRoot(error, expectedURL: layout.symlinkedRoot)
        }
    }

    @Test(
        "unrotatedSegmentURLIfRegular fails closed on symlinked root",
        .tags(.lgp2)
    )
    func unrotatedSegmentURLIfRegularRejectsSymlinkedRoot() throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }
        try Data().write(to: layout.realDir.appendingPathComponent("log.ndjson"))

        do {
            _ = try SegmentEnumeration.unrotatedSegmentURLIfRegular(
                in: layout.symlinkedRoot, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            Self.assertEnumerateFailedAtRoot(error, expectedURL: layout.symlinkedRoot)
        }
    }
}

// MARK: - Read-side: AcceptedLineIterator

extension SymlinkedConfiguredRootTests {
    @Test(
        "Under .never, AcceptedLineIterator with symlinked root fails before yielding",
        .tags(.lgp2)
    )
    func neverIteratorRejectsSymlinkedRoot() async throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }
        try Data().write(to: layout.realDir.appendingPathComponent("log.ndjson"))

        let configuration = FileLogStore.Configuration(
            directory: layout.symlinkedRoot, rotation: .never
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
            Self.assertEnumerateFailedAtRoot(error, expectedURL: layout.symlinkedRoot)
        }
    }

    @Test(
        "Under .bySize, AcceptedLineIterator with symlinked root fails before yielding",
        .tags(.lgp2, .lgp6)
    )
    func bySizeIteratorRejectsSymlinkedRoot() async throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }
        try Data().write(to: layout.realDir.appendingPathComponent("log.000001.ndjson"))

        let configuration = FileLogStore.Configuration(
            directory: layout.symlinkedRoot,
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
            Self.assertEnumerateFailedAtRoot(error, expectedURL: layout.symlinkedRoot)
        }
    }
}

// MARK: - Write-side: FileLogStore append

extension SymlinkedConfiguredRootTests {
    @Test(
        "Under .never, append with symlinked root fails closed; target stays without log.ndjson",
        .tags(.lgp2, .lgp24, .lgp25)
    )
    func neverAppendRejectsSymlinkedRoot() async throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        let store = FileLogStore(configuration: .init(directory: layout.symlinkedRoot))
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected FileLogStoreError.operationFailed")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .createDirectory)
                #expect(url == layout.symlinkedRoot)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
        try Self.assertTargetDirectoryUnmodified(layout.realDir)
    }

    @Test(
        "Under .bySize, append with symlinked root fails closed; target stays without log.000001.ndjson",
        .tags(.lgp2, .lgp6, .lgp24, .lgp25)
    )
    func bySizeAppendRejectsSymlinkedRoot() async throws {
        let layout = try Self.makeSymlinkedRoot()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        let configuration = FileLogStore.Configuration(
            directory: layout.symlinkedRoot,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let store = FileLogStore(configuration: configuration)
        let envelope = try Self.canonicalEnvelope(sequence: 1)

        do {
            try await store.append(envelope)
            Issue.record("expected FileLogStoreError.operationFailed")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .createDirectory)
                #expect(url == layout.symlinkedRoot)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }
        try Self.assertTargetDirectoryUnmodified(layout.realDir)
    }
}
