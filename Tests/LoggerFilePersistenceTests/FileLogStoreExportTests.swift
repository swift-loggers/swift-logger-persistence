import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Byte-stable export coverage for `FileLogStore.exportLogs(to:)`.
@Suite("FileLogStore byte-stable export")
struct FileLogStoreExportTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeStore(
        directory: URL,
        rotation: RotationPolicy
    ) -> FileLogStore {
        FileLogStore(configuration: .init(directory: directory, rotation: rotation))
    }

    /// Returns a unique export destination URL and its owning
    /// parent directory. The caller owns the parent's removal.
    private static func makeUniqueDestination() throws -> (destination: URL, parent: URL) {
        let parent = uniqueDirectory()
        try makeDirectory(parent)
        return (parent.appendingPathComponent("export.ndjson"), parent)
    }

    /// Builds a `(envelope, accepted bytes)` pair with a
    /// 1-byte payload. The returned bytes are the accepted
    /// line that append writes and byte-stable export preserves.
    private static func makeSingleByteEnvelopeAndLine(
        sequence: UInt64
    ) throws -> (PersistentLogEnvelope, Data) {
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: sequence, payload: Data([0x01])
        )
        return (envelope, try CanonicalEnvelopeLineEncoder().encode(envelope))
    }

    /// Bound on every semaphore wait the single-flight test
    /// performs. Five seconds is generous for a fast unit test
    /// while still preventing an indefinite hang when a test seam
    /// is not released.
    private static let singleFlightWaitTimeout: DispatchTimeInterval = .seconds(5)

    /// Installs the export-pause + append-entry + append-exit
    /// test seams used by the single-flight test. The release
    /// wait inside the export test seam is bounded so a missing
    /// release signal fails the test deterministically instead
    /// of hanging indefinitely.
    private static func wireSingleFlightTestSeams(
        on store: FileLogStore,
        exportPaused: DispatchSemaphore,
        releaseExport: DispatchSemaphore,
        recorder: ActorActivityRecorder
    ) async {
        await store._setOnAfterWritingTemporaryBytesForTesting {
            recorder.record("export-paused")
            exportPaused.signal()
            let released = releaseExport.wait(
                timeout: .now() + singleFlightWaitTimeout
            ) == .success
            recorder.record(released ? "export-released" : "export-release-timeout")
        }
        await store._setOnBeforeAppendForTesting {
            recorder.record("append-entered")
        }
        await store._setOnAfterAppendForTesting {
            recorder.record("append-completed")
        }
    }

    /// Bridges a bounded `DispatchSemaphore.wait()`
    /// into the async test body without blocking the test's
    /// executor. Returns `true` on signal, `false` on timeout;
    /// the test treats `false` as a recorded failure rather than
    /// a hang.
    private static func awaitSemaphoreWait(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTimeInterval
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let waited = semaphore.wait(timeout: .now() + timeout) == .success
                cont.resume(returning: waited)
            }
        }
    }

    private static func appendCanonicalLines(
        store: FileLogStore, sequences: ClosedRange<UInt64>,
        payload: Data = Data([0x01])
    ) async throws -> Data {
        var concat = Data()
        for sequence in sequences {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence, payload: payload
            )
            try await store.append(envelope)
            concat.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        return concat
    }
}

// MARK: - Cleanup contract

extension FileLogStoreExportTests {
    @Test(
        "Interior corruption mid-scan aborts export, final URL absent, no temp leftover",
        .tags(.lgp8, .lgp17, .lgp32, .lgp35, .lgp37)
    )
    func interiorCorruptionAbortsCleanup() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        // One accepted line + interior-corrupt LF-terminated non-JSON.
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        var bytes = try Data(contentsOf: segmentURL)
        bytes.append(Data("[1,2,3]\n".utf8))
        try bytes.write(to: segmentURL)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected interiorCorruption")
        } catch {
            switch error {
            case let .interiorCorruption(seg, _, classification):
                #expect(seg == segmentURL)
                #expect(classification == .nonObjectJSON)
            default:
                Issue.record("expected .interiorCorruption, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: destinationParent.path)
        #expect(leftovers == [])
    }

    @Test(
        "Destination materialized between pre-check and commit fails closed without overwriting",
        .tags(.lgp2, .lgp8, .lgp24, .lgp25, .lgp32)
    )
    func commitRaceWithMaterializedDestination() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(store: store, sequences: 1 ... 1)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        // Plant a regular file at the final URL between final
        // pre-check and the atomic commit. Export is executing
        // inside the actor-isolated operation, and the seam runs
        // synchronously inside that operation, so this is the
        // deterministic window where the race can be exercised.
        let plantedBytes = Data("PLANTED\n".utf8)
        let plantedPath = destination.path
        await store._setOnBeforeCommitForTesting {
            try plantedBytes.write(to: URL(fileURLWithPath: plantedPath))
        }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.alreadyExistsAsRegularFile)")
        } catch {
            switch error {
            case .invalidDestination(.alreadyExistsAsRegularFile):
                ()
            default:
                Issue.record("expected .alreadyExistsAsRegularFile, got \(error)")
            }
        }

        // Planted file is preserved byte-identical.
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == plantedBytes)
        // Temp file was unlinked from the parent directory; only
        // the planted final remains.
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: destinationParent.path)
        #expect(entries == ["export.ndjson"])
    }

    @Test(
        "Write-failure seam aborts export, final URL absent, no temp leftover",
        .tags(.lgp8, .lgp24, .lgp25, .lgp32)
    )
    func writeFailureSeamAbortsCleanup() async throws {
        struct SentinelError: Error, Equatable {}

        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(store: store, sequences: 1 ... 1)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        await store._setOnAfterWritingTemporaryBytesForTesting {
            throw SentinelError()
        }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected operationFailed(.writeTemporaryDestinationBytes)")
        } catch {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .writeTemporaryDestinationBytes)
            default:
                Issue.record("expected .operationFailed, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: destinationParent.path)
        #expect(leftovers == [])
    }

    @Test(
        "Close-failure seam aborts export with .closeTemporaryDestination, final URL absent, no temp leftover",
        .tags(.lgp8, .lgp24, .lgp25, .lgp32)
    )
    func closeFailureSeamAbortsCleanup() async throws {
        struct SentinelError: Error, Equatable {}

        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(store: store, sequences: 1 ... 1)

        let (destination, parent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(parent) }

        await store._setOnCloseTemporaryDestinationForTesting {
            throw SentinelError()
        }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected operationFailed(.closeTemporaryDestination)")
        } catch {
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .closeTemporaryDestination)
            default:
                Issue.record("expected .closeTemporaryDestination, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(leftovers == [])
    }
}

// MARK: - Byte-exact contract

extension FileLogStoreExportTests {
    @Test(
        "Empty recoverable prefix yields a 0-byte export file",
        .tags(.lgp8, .lgp32)
    )
    func emptyRecoverablePrefixYieldsZeroBytes() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk.isEmpty)
    }

    @Test(
        "Export succeeds when destination filename is near NAME_MAX",
        .tags(.lgp8, .lgp24, .lgp25, .lgp32)
    )
    func longDestinationFilenameExportSucceeds() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        let expected = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 1
        )
        try await store.flush()

        // 220-byte leaf — valid (< NAME_MAX = 255) — but large
        // enough that a temp leaf prefixed with the final leaf
        // (`.{leaf}.export-{uuid}.tmp`) would overflow NAME_MAX.
        let leafName = String(repeating: "a", count: 213) + ".ndjson"
        #expect(leafName.utf8.count == 220)
        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent(leafName)

        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == expected)
    }

    @Test(
        "Multi-segment .bySize export concatenates rotated segments byte-for-byte in numeric order",
        .tags(.lgp6, .lgp8, .lgp27, .lgp32, .lgp39)
    )
    func bySizeMultiSegmentByteExact() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = Self.makeStore(directory: directory, rotation: policy)

        // Each large-payload envelope is roughly half the cap; two
        // appends fill segment 1, the third rolls into segment 2.
        var expected = Data()
        for sequence in 1 ... 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence)
            )
            try await store.append(envelope)
            expected.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        try await store.flush()

        let destination = directory.appendingPathComponent("export.ndjson")
        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == expected)
    }

    @Test(
        "Single-segment .never export reads only the recoverable prefix; trailing partial bytes are excluded",
        .tags(.lgp8, .lgp14, .lgp15, .lgp27, .lgp32)
    )
    func neverExportUsesRecoverablePrefix() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        let expected = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 3
        )
        try await store.flush()

        // Append unaligned trailing partial bytes after the last LF.
        let segmentURL = directory.appendingPathComponent("log.ndjson")
        var bytes = try Data(contentsOf: segmentURL)
        bytes.append(Data([0x7B, 0x22])) // `{"`
        try bytes.write(to: segmentURL)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == expected)
    }

    @Test(
        "Duplicate sequences across segments are preserved verbatim in the export",
        .tags(.lgp8, .lgp27, .lgp32)
    )
    func duplicateSequencesPreserved() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = Self.makeStore(directory: directory, rotation: policy)

        // Append three envelopes; the third forces rotation. All
        // share `sequence == 1` to prove duplicates are passed
        // through untouched.
        var expected = Data()
        for _ in 0 ..< 3 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
            try await store.append(envelope)
            expected.append(try CanonicalEnvelopeLineEncoder().encode(envelope))
        }
        try await store.flush()

        let destination = directory.appendingPathComponent("export.ndjson")
        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == expected)
    }

    @Test(
        "Export ends with the last accepted line's trailing LF; no extra terminator or footer is appended",
        .tags(.lgp8, .lgp26, .lgp27, .lgp32)
    )
    func trailingLFPreserved() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        let expected = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 2
        )
        try await store.flush()

        let destination = directory.appendingPathComponent("export.ndjson")
        try await store.exportLogs(to: destination)
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == expected)
        #expect(onDisk.last == 0x0A)
    }
}

// MARK: - Single-flight serialization

extension FileLogStoreExportTests {
    @Test(
        "Concurrent append cannot complete before export critical section releases",
        .tags(.lgp8, .lgp19, .lgp24, .lgp25, .lgp32)
    )
    func singleFlightAgainstConcurrentAppend() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeStore(directory: directory, rotation: .never)
        let expectedPrefix = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 5
        )
        try await store.flush()
        let (extra, extraLine) = try Self.makeSingleByteEnvelopeAndLine(sequence: 6)
        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }

        // Three synchronous signals drive the test:
        // - exportPaused: signaled inside the export critical
        //   section once the actor-isolated export operation is
        //   executing; export then blocks on releaseExport.
        // - appendCallPathReached: signaled by the append task
        //   body immediately before `await store.append(...)`;
        //   proves the call-path was reached before release, so
        //   the test exercises concurrent export-against-append
        //   rather than sequential after-release scheduling.
        // - releaseExport: signaled by the test after the append
        //   call-path has been reached; lets export finish.
        //
        // The strict equality check on the recorded event order
        // is the single-flight proof: append's actor-isolated
        // interval (`append-entered` … `append-completed`) must
        // sit entirely after `export-released` because the actor
        // mutex queues the append call behind export.
        let exportPaused = DispatchSemaphore(value: 0)
        let appendCallPathReached = DispatchSemaphore(value: 0)
        let releaseExport = DispatchSemaphore(value: 0)
        let recorder = ActorActivityRecorder()
        await Self.wireSingleFlightTestSeams(
            on: store,
            exportPaused: exportPaused,
            releaseExport: releaseExport,
            recorder: recorder
        )

        let timeout = Self.singleFlightWaitTimeout
        let exportTask = Task { try await store.exportLogs(to: destination) }
        // Wait until export is inside the gate. Each wait is
        // bounded; on timeout the test records a failure but
        // still drains the tasks below so the suite cannot hang.
        if !(await Self.awaitSemaphoreWait(exportPaused, timeout: timeout)) {
            Issue.record("export did not reach pause gate within timeout")
        }

        let appendTask = Task {
            // Signal that the task body reached the call-path for
            // `store.append`; the next instruction submits the
            // actor call.
            appendCallPathReached.signal()
            try await store.append(extra)
        }
        if !(await Self.awaitSemaphoreWait(appendCallPathReached, timeout: timeout)) {
            Issue.record("append task did not reach call-path within timeout")
        }

        releaseExport.signal()
        _ = try? await exportTask.value
        _ = try? await appendTask.value
        try await store.flush()

        let finalEvents = recorder.snapshot()
        #expect(finalEvents == [
            "export-paused",
            "export-released",
            "append-entered",
            "append-completed"
        ])

        let exportBytes = try Data(contentsOf: destination)
        #expect(exportBytes == expectedPrefix)
        let segmentBytes = try Data(
            contentsOf: directory.appendingPathComponent("log.ndjson")
        )
        #expect(segmentBytes == expectedPrefix + extraLine)
    }
}

// MARK: - Local helpers

private final class ActorActivityRecorder: @unchecked Sendable {
    private var events: [String] = []
    private let lock = NSLock()

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
