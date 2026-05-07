import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Serialization coverage for `removeExportedLogs()` against append,
/// export, and operation-boundary cleanup failures.
@Suite("FileLogStore destructive removal — serialization")
struct FileLogStoreRemoveConcurrencyTests {
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

    /// Outer bound on the rendezvous awaits. Fires only at the
    /// test boundary; never inside an actor critical section.
    private static let rendezvousTimeout: Duration = .seconds(30)

    private static func makeBoundedStore(
        directory: URL
    ) async throws -> (store: FileLogStore, exportParent: URL) {
        try makeDirectory(directory)
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: .never)
        )
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()
        let (exportURL, exportParent) = try makeUniqueDestination()
        try await store.exportLogs(to: exportURL)
        return (store, exportParent)
    }
}

// MARK: - remove vs append

extension FileLogStoreRemoveConcurrencyTests {
    // swiftlint:disable function_body_length
    // Reason: deterministic async cleanup keeps the serialization test above the default limit.

    @Test(
        "Concurrent append cannot complete before remove critical section releases",
        .tags(.lgp9, .lgp25)
    )
    func appendSerializedAgainstRemove() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, exportParent) = try await Self.makeBoundedStore(
            directory: directory
        )
        defer { FileLogStoreTestSupport.remove(exportParent) }

        let removeRendezvous = TestRendezvous()
        let appendStarted = TestRendezvous()
        let recorder = SerializationRecorder()
        await Self.wireRemoveAppendOrderingSeams(
            on: store, rendezvous: removeRendezvous, recorder: recorder
        )

        // Ensure failure paths do not leave paused operation-boundary holders behind.
        var removeTask: Task<Void, any Error>?
        var appendTask: Task<Void, any Error>?
        do {
            removeTask = Task { try await store.removeExportedLogs() }
            try await withTestTimeout(
                Self.rendezvousTimeout,
                description: "remove did not reach pause point"
            ) {
                await removeRendezvous.awaitPaused()
            }

            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: 2, payload: Data([0x02])
            )
            appendTask = Task {
                await appendStarted.signalPaused()
                try await store.append(envelope)
            }
            try await withTestTimeout(
                Self.rendezvousTimeout,
                description: "append task body did not start"
            ) {
                await appendStarted.awaitPaused()
            }

            // Pre-release proof: append cannot have entered the
            // operation body — the operation boundary is held by
            // remove.
            let preReleaseEvents = recorder.snapshot()
            #expect(!preReleaseEvents.contains("append-entered"))
            #expect(!preReleaseEvents.contains("append-completed"))

            await removeRendezvous.signalRelease()
            try await removeTask?.value
            try await appendTask?.value
        } catch {
            await releaseCancelAndDrain(
                rendezvous: removeRendezvous,
                tasks: [removeTask, appendTask].compactMap(\.self),
                context: "appendSerializedAgainstRemove"
            )
            throw error
        }

        let events = recorder.snapshot()
        #expect(events == [
            "remove-paused",
            "remove-released",
            "append-entered",
            "append-completed"
        ])
    }

    // swiftlint:enable function_body_length

    private static func wireRemoveAppendOrderingSeams(
        on store: FileLogStore,
        rendezvous: TestRendezvous,
        recorder: SerializationRecorder
    ) async {
        await store._setOnBeforeProcessRemovalEntryForTesting { _ in
            recorder.record("remove-paused")
            await rendezvous.signalPaused()
            await rendezvous.awaitRelease()
            recorder.record("remove-released")
        }
        await store._setOnBeforeAppendForTesting {
            recorder.record("append-entered")
        }
        await store._setOnAfterAppendForTesting {
            recorder.record("append-completed")
        }
    }
}

// MARK: - remove vs export

extension FileLogStoreRemoveConcurrencyTests {
    // swiftlint:disable function_body_length
    // Reason: deterministic async cleanup keeps the serialization test above the default limit.

    @Test(
        "Concurrent export cannot complete before remove critical section releases",
        .tags(.lgp8, .lgp9)
    )
    func exportSerializedAgainstRemove() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let (store, exportParent) = try await Self.makeBoundedStore(
            directory: directory
        )
        defer { FileLogStoreTestSupport.remove(exportParent) }

        let removeRendezvous = TestRendezvous()
        let exportStarted = TestRendezvous()
        let recorder = SerializationRecorder()
        await store._setOnBeforeProcessRemovalEntryForTesting { _ in
            recorder.record("remove-paused")
            await removeRendezvous.signalPaused()
            await removeRendezvous.awaitRelease()
            recorder.record("remove-released")
        }
        await store._setOnAfterWritingTemporaryBytesForTesting {
            recorder.record("export-byte-write-completed")
        }

        let (secondExportURL, secondExportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(secondExportParent) }

        // Ensure failure paths do not leave paused operation-boundary holders behind.
        var removeTask: Task<Void, any Error>?
        var exportTask: Task<Void, any Error>?
        do {
            removeTask = Task { try await store.removeExportedLogs() }
            try await withTestTimeout(
                Self.rendezvousTimeout,
                description: "remove did not reach pause point"
            ) {
                await removeRendezvous.awaitPaused()
            }

            exportTask = Task {
                await exportStarted.signalPaused()
                try await store.exportLogs(to: secondExportURL)
            }
            try await withTestTimeout(
                Self.rendezvousTimeout,
                description: "export task body did not start"
            ) {
                await exportStarted.awaitPaused()
            }

            // Pre-release proof: export's post-write seam cannot
            // have fired — the operation boundary is held by remove.
            let preReleaseEvents = recorder.snapshot()
            #expect(!preReleaseEvents.contains("export-byte-write-completed"))

            await removeRendezvous.signalRelease()
            try await removeTask?.value
            try await exportTask?.value
        } catch {
            await releaseCancelAndDrain(
                rendezvous: removeRendezvous,
                tasks: [removeTask, exportTask].compactMap(\.self),
                context: "exportSerializedAgainstRemove"
            )
            throw error
        }

        let events = recorder.snapshot()
        #expect(events == [
            "remove-paused",
            "remove-released",
            "export-byte-write-completed"
        ])
    }

    // swiftlint:enable function_body_length
}

// MARK: - Local recorder

private final class SerializationRecorder: @unchecked Sendable {
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
