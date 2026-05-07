// swiftlint:disable file_length - Byte-stable export coverage centralizes destination-topology, atomicity, single-flight, byte-equality, and private-temp-directory confidentiality proofs in one suite for review locality.
import Darwin
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

    private static func makeExportStore(
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

    /// Outer bound on the single-flight test's rendezvous
    /// awaits. Fires only at the test boundary; never inside
    /// an actor critical section.
    private static let singleFlightRendezvousTimeout: Duration = .seconds(30)

    /// Installs the export-pause + append-entry + append-exit
    /// test seams used by the single-flight test. The export
    /// seam suspends asynchronously through the rendezvous
    /// instead of blocking the cooperative pool.
    private static func wireSingleFlightTestSeams(
        on store: FileLogStore,
        rendezvous: TestRendezvous,
        recorder: ActorActivityRecorder
    ) async {
        await store._setOnAfterWritingTemporaryBytesForTesting {
            recorder.record("export-paused")
            await rendezvous.signalPaused()
            await rendezvous.awaitRelease()
            recorder.record("export-released")
        }
        await store._setOnBeforeAppendForTesting {
            recorder.record("append-entered")
        }
        await store._setOnAfterAppendForTesting {
            recorder.record("append-completed")
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
        let store = Self.makeExportStore(directory: directory, rotation: .never)

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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(store: store, sequences: 1 ... 1)

        let destinationParent = Self.uniqueDirectory()
        try Self.makeDirectory(destinationParent)
        defer { FileLogStoreTestSupport.remove(destinationParent) }
        let destination = destinationParent.appendingPathComponent("export.ndjson")

        // Plant a regular file at the final URL between final
        // pre-check and the atomic commit. Export is executing
        // while holding the nonreentrant operation boundary, and
        // the seam runs synchronously before the atomic commit,
        // so this is the deterministic window where the race can
        // be exercised.
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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
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
        let store = Self.makeExportStore(directory: directory, rotation: .never)

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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
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
        let store = Self.makeExportStore(directory: directory, rotation: policy)

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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
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
        let store = Self.makeExportStore(directory: directory, rotation: policy)

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
        let store = Self.makeExportStore(directory: directory, rotation: .never)
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
    // swiftlint:disable function_body_length
    // Reason: Async rendezvous + outer-timeout helpers wrap the locked single-flight assertion sequence per LGP-19/24/25/32.

    @Test(
        "Concurrent append cannot complete before export critical section releases",
        .tags(.lgp8, .lgp19, .lgp24, .lgp25, .lgp32)
    )
    func singleFlightAgainstConcurrentAppend() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeExportStore(directory: directory, rotation: .never)
        let expectedPrefix = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 5
        )
        try await store.flush()
        let (extra, extraLine) = try Self.makeSingleByteEnvelopeAndLine(sequence: 6)
        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }

        // Two async rendezvous instances drive the test:
        // - `exportRendezvous` pauses the export critical section
        //   inside the post-write seam and releases it on the
        //   test's command. The seam awaits on a continuation —
        //   no cooperative-pool thread is blocked.
        // - `appendStarted` proves the append task body has
        //   begun executing before the test signals release, so
        //   the proof exercises concurrent-against-export rather
        //   than sequential after-release scheduling.
        //
        // The strict equality check on the recorded event order
        // is the single-flight proof: append's body interval
        // (`append-entered` … `append-completed`) must sit
        // entirely after `export-released` because the operation
        // boundary holds across export's await suspensions and
        // queues the append call behind export.
        let exportRendezvous = TestRendezvous()
        let appendStarted = TestRendezvous()
        let recorder = ActorActivityRecorder()
        await Self.wireSingleFlightTestSeams(
            on: store, rendezvous: exportRendezvous, recorder: recorder
        )

        // Failure-path cleanup: any throw between starting the
        // first task and successfully draining both must release
        // the rendezvous, cancel every started task, and
        // bounded-drain task results so the test never leaves a
        // paused holder behind or a queued waiter blocked on a
        // non-cancelable operation boundary.
        var exportTask: Task<Void, any Error>?
        var appendTask: Task<Void, any Error>?
        do {
            exportTask = Task { try await store.exportLogs(to: destination) }
            try await withTestTimeout(
                Self.singleFlightRendezvousTimeout,
                description: "export did not reach pause point"
            ) {
                await exportRendezvous.awaitPaused()
            }

            appendTask = Task {
                await appendStarted.signalPaused()
                try await store.append(extra)
            }
            try await withTestTimeout(
                Self.singleFlightRendezvousTimeout,
                description: "append task body did not start"
            ) {
                await appendStarted.awaitPaused()
            }

            // Pre-release proof: append cannot have entered the
            // operation body — the operation boundary is held by
            // export. Recording any append event here would
            // contradict the single-flight contract.
            let preReleaseEvents = recorder.snapshot()
            #expect(!preReleaseEvents.contains("append-entered"))
            #expect(!preReleaseEvents.contains("append-completed"))

            await exportRendezvous.signalRelease()
            try await exportTask?.value
            try await appendTask?.value
        } catch {
            await releaseCancelAndDrain(
                rendezvous: exportRendezvous,
                tasks: [exportTask, appendTask].compactMap(\.self),
                context: "singleFlightAgainstConcurrentAppend"
            )
            throw error
        }
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

    // swiftlint:enable function_body_length
}

// MARK: - Private temp directory confidentiality

extension FileLogStoreExportTests {
    // swiftlint:disable function_body_length
    // Reason: Pre-commit topology proof, sentinel-based umask-filtered final-mode comparison, and post-commit cleanup all live in one body to keep the private-temp-dir contract locally auditable.

    @Test(
        "Export confines payload bytes to a private temp directory; no readable temp file in destination parent",
        .tags(.lgp8, .lgp24, .lgp25, .lgp32)
    )
    func exportConfinedToPrivateTempDirectory() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeExportStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 1
        )
        try await store.flush()
        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }

        // Observe destination-parent topology during the
        // pre-commit window: payload bytes must be inside the
        // private temp directory, not as a readable regular
        // temp file in the parent.
        let observer = PrivateTempDirObserver()
        let parentPath = destinationParent.path
        await store._setOnBeforeCommitForTesting {
            observer.observe(parentPath: parentPath)
        }

        try await store.exportLogs(to: destination)

        let preCommit = observer.snapshot
        // Exactly one entry in parent during write phase: the
        // private temp directory.
        #expect(preCommit.parentEntries.count == 1)
        if let only = preCommit.parentEntries.first {
            #expect(only.hasPrefix(".swift-logger-export-"))
            #expect(only.hasSuffix(".tmpdir"))
        }
        // Private temp directory: directory type, owner-only mode.
        #expect(preCommit.tempDirIsDirectory)
        #expect(preCommit.tempDirMode == 0o700)
        // No readable regular temp file in destination parent
        // during the write phase.
        #expect(preCommit.parentRegularFiles.isEmpty)

        // Post-commit: final destination exists, private temp
        // directory is gone.
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let postEntries = try FileManager.default
            .contentsOfDirectory(atPath: destinationParent.path)
        let leftoverTempDirs = postEntries.filter {
            $0.hasPrefix(".swift-logger-export-") && $0.hasSuffix(".tmpdir")
        }
        #expect(leftoverTempDirs.isEmpty)

        // Final destination mode matches what the platform
        // umask filters from `0o666`. Compute the expected mode
        // by creating a sentinel file with the same `0o666` arg
        // and reading its applied mode — avoids any
        // `Darwin.umask(0)` lookup in the test path.
        let sentinelURL = destinationParent
            .appendingPathComponent("__umask-sentinel__")
        let sentinelFD = sentinelURL.path.withCString { cPath in
            Darwin.open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        }
        try #require(sentinelFD >= 0)
        var sentinelStat = stat()
        let sentinelStatResult = Darwin.fstat(sentinelFD, &sentinelStat)
        _ = Darwin.close(sentinelFD)
        try? FileManager.default.removeItem(at: sentinelURL)
        try #require(sentinelStatResult == 0)
        let expectedMode = mode_t(sentinelStat.st_mode & 0o777)

        var finalStat = stat()
        let finalStatResult = destination.path.withCString { cPath in
            Darwin.lstat(cPath, &finalStat)
        }
        try #require(finalStatResult == 0)
        let actualMode = mode_t(finalStat.st_mode & 0o777)
        #expect(actualMode == expectedMode)
    }

    // swiftlint:enable function_body_length

    @Test(
        "Export failure before commit removes private temp directory and payload",
        .tags(.lgp8, .lgp24, .lgp25, .lgp32)
    )
    func exportFailureCleansUpPrivateTempDirectory() async throws {
        struct SentinelError: Error {}

        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = Self.makeExportStore(directory: directory, rotation: .never)
        _ = try await Self.appendCanonicalLines(
            store: store, sequences: 1 ... 1
        )
        try await store.flush()
        let (destination, destinationParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(destinationParent) }

        await store._setOnAfterWritingTemporaryBytesForTesting {
            throw SentinelError()
        }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected forced failure before commit")
        } catch {
            // The post-write seam projects onto
            // `.operationFailed(.writeTemporaryDestinationBytes)`
            // — asserting the specific projection prevents the
            // cleanup proof below from masking an unrelated
            // earlier failure.
            switch error {
            case let .operationFailed(operation, _, _):
                #expect(operation == .writeTemporaryDestinationBytes)
            default:
                Issue.record(
                    "expected .operationFailed(.writeTemporaryDestinationBytes), got \(error)"
                )
            }
        }

        // Failure path cleanup: no leftover private temp
        // directory, no leftover payload, no final destination.
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: destinationParent.path)
        let leftover = entries.filter { $0.hasPrefix(".swift-logger-export-") }
        #expect(leftover.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
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

private final class PrivateTempDirObserver: @unchecked Sendable {
    struct Snapshot: Sendable {
        var parentEntries: [String] = []
        var parentRegularFiles: [String] = []
        var tempDirMode: mode_t = 0
        var tempDirIsDirectory: Bool = false
    }

    private let lock = NSLock()
    private var current = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func observe(parentPath: String) {
        let parentURL = URL(fileURLWithPath: parentPath)
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
        else { return }
        var snapshot = Snapshot()
        snapshot.parentEntries = entries.map(\.lastPathComponent)
        for entry in entries {
            var statBuf = stat()
            let result = entry.path.withCString { cPath in
                Darwin.lstat(cPath, &statBuf)
            }
            guard result == 0 else { continue }
            let kind = statBuf.st_mode & S_IFMT
            if kind == S_IFDIR, entry.lastPathComponent.hasSuffix(".tmpdir") {
                snapshot.tempDirMode = mode_t(statBuf.st_mode & 0o777)
                snapshot.tempDirIsDirectory = true
            }
            if kind == S_IFREG {
                snapshot.parentRegularFiles.append(entry.lastPathComponent)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        current = snapshot
    }
}
