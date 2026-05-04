import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// TOCTOU regression coverage for descriptor-relative writer opens.
@Suite("FileLogStore writer mid-scan TOCTOU rejection")
struct FileLogStoreWriterMidScanTOCTOUTests {
    private struct WriterLayout {
        let parent: URL
        let configured: URL
        let renamed: URL
        let attacker: URL
    }

    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Builds configured, renamed-original, and attacker roots for swap tests.
    private static func makeWriterLayout() throws -> WriterLayout {
        let parent = Self.uniqueDirectory()
        try Self.makeDirectory(parent)
        let configured = parent.appendingPathComponent("real-configured")
        try Self.makeDirectory(configured)
        let attacker = parent.appendingPathComponent("real-attacker")
        try Self.makeDirectory(attacker)
        let renamed = parent.appendingPathComponent("renamed-original")
        return WriterLayout(
            parent: parent, configured: configured, renamed: renamed, attacker: attacker
        )
    }

    /// Returns a one-shot hook that swaps the configured root with the attacker root.
    private static func swapHook(for layout: WriterLayout) -> @Sendable () throws -> Void {
        // Capture absolute paths (URLs are not perfectly Sendable
        // on every toolchain) and use FileManager for the swap.
        let configuredPath = layout.configured.path
        let renamedPath = layout.renamed.path
        let attackerPath = layout.attacker.path
        let didSwap = ManagedAtomic(false)
        return {
            guard didSwap.compareExchange(expected: false, desired: true) else { return }
            let manager = FileManager.default
            try manager.moveItem(atPath: configuredPath, toPath: renamedPath)
            try manager.moveItem(atPath: attackerPath, toPath: configuredPath)
        }
    }

    private static func sortedEntries(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

extension FileLogStoreWriterMidScanTOCTOUTests {
    @Test(
        "bySize root swap writes through held descriptor",
        .tags(.lgp2, .lgp6, .lgp14, .lgp24, .lgp25)
    )
    func bySizeDiscoveryAndOpenStaysOnHeldRoot() async throws {
        let layout = try Self.makeWriterLayout()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        // Pre-existing empty rotated segment so highest discovery
        // returns 5 and the writer reopens that segment for append.
        try Data().write(to: FileLogStoreTestSupport.rotatedSegmentURL(
            in: layout.configured, sequence: 5
        ))

        let configuration = FileLogStore.Configuration(
            directory: layout.configured,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let store = FileLogStore(configuration: configuration)
        await store._setOnBeforeOpenWritableSegmentForTesting(Self.swapHook(for: layout))

        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()

        // Attacker directory at the configured path must be unchanged.
        #expect(try Self.sortedEntries(at: layout.configured) == [])
        // The original root receives the append through the held descriptor.
        #expect(try Self.sortedEntries(at: layout.renamed) == ["log.000005.ndjson"])
        let onDisk = try Data(contentsOf: layout.renamed.appendingPathComponent("log.000005.ndjson"))
        #expect(!onDisk.isEmpty)
    }

    @Test(
        "never root swap writes through held descriptor",
        .tags(.lgp2, .lgp14, .lgp24, .lgp25)
    )
    func neverCreateAndOpenStaysOnHeldRoot() async throws {
        let layout = try Self.makeWriterLayout()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        let configuration = FileLogStore.Configuration(
            directory: layout.configured, rotation: .never
        )
        let store = FileLogStore(configuration: configuration)
        await store._setOnBeforeOpenWritableSegmentForTesting(Self.swapHook(for: layout))

        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()

        #expect(try Self.sortedEntries(at: layout.configured) == [])
        #expect(try Self.sortedEntries(at: layout.renamed) == ["log.ndjson"])
    }

    @Test(
        "initial root swap is rejected",
        .tags(.lgp2, .lgp14, .lgp24, .lgp25)
    )
    func initialAcquisitionRejectsRootSwap() async throws {
        let layout = try Self.makeWriterLayout()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        let configuration = FileLogStore.Configuration(
            directory: layout.configured, rotation: .never
        )
        let store = FileLogStore(configuration: configuration)
        // Hook fires AFTER createDirectoryIfNeeded captured the
        // root identity but BEFORE SegmentRoot.open. The post-open
        // identity check sees a different inode and must reject.
        await store._setOnBeforeWriterRootOpenForTesting(Self.swapHook(for: layout))

        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        do {
            try await store.append(envelope)
            Issue.record("expected operationFailed(.openWritableSegment)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .openWritableSegment)
                #expect(url == layout.configured)
            default:
                Issue.record("expected operationFailed, got \(error)")
            }
        }

        // The replacement directory now at the configured path must
        // be byte-empty; the original root (now at the renamed path)
        // must not have gained any segment file.
        #expect(try Self.sortedEntries(at: layout.configured) == [])
        #expect(try Self.sortedEntries(at: layout.renamed) == [])
    }

    @Test(
        "rotation root swap writes through held descriptor",
        .tags(.lgp2, .lgp6, .lgp14, .lgp24, .lgp25)
    )
    func rotationStaysOnHeldRoot() async throws {
        let layout = try Self.makeWriterLayout()
        defer { FileLogStoreTestSupport.remove(layout.parent) }

        let configuration = FileLogStore.Configuration(
            directory: layout.configured,
            rotation: try .bySize(maxSegmentBytes: FileLogStore.maxEncodedLineBytes)
        )
        let store = FileLogStore(configuration: configuration)

        // First append establishes log.000001.ndjson in the held root.
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        try await store.append(envelope1)

        // Arm the seam only after the first segment is open so the
        // first append is unaffected; the next append triggers
        // rotation and the hook fires before the segment-2 open.
        await store._setOnBeforeOpenWritableSegmentForTesting(Self.swapHook(for: layout))

        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(sequence: 2)
        try await store.append(envelope2)
        try await store.flush()

        #expect(try Self.sortedEntries(at: layout.configured) == [])
        #expect(try Self.sortedEntries(at: layout.renamed) == [
            "log.000001.ndjson", "log.000002.ndjson"
        ])
    }
}

// MARK: - Local atomic helper

/// One-shot atomic flag for the hook closure. The hook needs to
/// fire exactly once per test, even if the writer reopens the seam
/// path during retry.
private final class ManagedAtomic<Value: Equatable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func compareExchange(expected: Value, desired: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == expected else { return false }
        value = desired
        return true
    }
}
