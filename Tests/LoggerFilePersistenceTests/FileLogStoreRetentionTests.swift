// swiftlint:disable file_length - LOCKED retention SQE matrix; kept in one file for traceability.

import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// SQE coverage for `RetentionPolicy` validation and
/// `.bySize` whole-segment enforcement.
@Suite("FileLogStore retention policy")
struct FileLogStoreRetentionTests {
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

    /// Builds a `.bySize` store where each test envelope rotates.
    static func makeRotatingStore(
        directory: URL,
        retention: RetentionPolicy
    ) throws -> FileLogStore {
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        return FileLogStore(
            configuration: .init(
                directory: directory,
                rotation: rotation,
                retention: retention
            )
        )
    }

    /// Returns the canonical encoded bytes for `sequence` so tests
    /// can match retained segment bytes byte-for-byte.
    static func encodedLine(
        for sequence: UInt64
    ) throws -> Data {
        try CanonicalEnvelopeLineEncoder().encode(
            FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
        )
    }

    /// Returns rotated segment names through the production
    /// descriptor-relative enumerator so retention assertions never
    /// run against a test-side shadow parser.
    private static func rotatedSegmentNames(
        in directory: URL
    ) throws -> [String] {
        let entries = try SegmentEnumeration.enumerateRotatedSegments(
            in: directory, fileManager: FileManager.default
        )
        return entries.map { $0.url.lastPathComponent }
    }

    private static func withInstalledSeam<Handler>(
        setter: @Sendable @escaping (Handler?) async -> Void,
        handler: Handler,
        body: () async throws -> Void
    ) async throws {
        await setter(handler)
        var capturedError: (any Error)?
        do {
            try await body()
        } catch {
            capturedError = error
        }
        await setter(nil)
        if let capturedError { throw capturedError }
    }

    private static func withRetentionUnlinkSeam(
        on store: FileLogStore,
        handler: @Sendable @escaping (URL) throws -> Void,
        body: () async throws -> Void
    ) async throws {
        try await withInstalledSeam(
            setter: { await store._setOnBeforeRetentionUnlinkForTesting($0) },
            handler: handler,
            body: body
        )
    }
}

// MARK: - RetentionPolicy validation

extension FileLogStoreRetentionTests {
    @Test(
        "`RetentionPolicy.maxSegments` rejects a count of zero",
        .tags(.lgp2, .lgp7)
    )
    func maxSegmentsRejectsZeroCount() {
        do {
            _ = try RetentionPolicy.maxSegments(0)
            Issue.record("expected .invalidRetentionPolicy for count = 0")
        } catch {
            #expect(error == .invalidRetentionPolicy)
        }
    }

    @Test(
        "`RetentionPolicy.maxSegments` rejects a negative count",
        .tags(.lgp2, .lgp7)
    )
    func maxSegmentsRejectsNegativeCount() {
        do {
            _ = try RetentionPolicy.maxSegments(-1)
            Issue.record("expected .invalidRetentionPolicy for negative count")
        } catch {
            #expect(error == .invalidRetentionPolicy)
        }
    }

    @Test(
        "`RetentionPolicy.maxSegments` accepts a count of one",
        .tags(.lgp7)
    )
    func maxSegmentsAcceptsOne() throws {
        _ = try RetentionPolicy.maxSegments(1)
    }

    @Test(
        "`RetentionPolicy.maxTotalBytes` rejects a cap below the encoded-line cap",
        .tags(.lgp2, .lgp7)
    )
    func maxTotalBytesRejectsCapBelowEncodedLineCap() {
        do {
            _ = try RetentionPolicy.maxTotalBytes(
                FileLogStore.maxEncodedLineBytes - 1
            )
            Issue.record(
                "expected .invalidRetentionPolicy for cap < encoded-line cap"
            )
        } catch {
            #expect(error == .invalidRetentionPolicy)
        }
    }

    @Test(
        "`RetentionPolicy.maxTotalBytes` accepts a cap exactly at the encoded-line cap",
        .tags(.lgp7)
    )
    func maxTotalBytesAcceptsCapAtEncodedLineCap() throws {
        _ = try RetentionPolicy.maxTotalBytes(FileLogStore.maxEncodedLineBytes)
    }
}

// MARK: - Configuration default

extension FileLogStoreRetentionTests {
    @Test(
        "`Configuration(directory:)` defaults retention to `.unlimited`",
        .tags(.lgp7)
    )
    func configurationDefaultsToUnlimitedRetention() {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let configuration = FileLogStore.Configuration(directory: directory)
        #expect(configuration.retention == .unlimited)
    }

    @Test(
        "`Configuration(directory:rotation:)` defaults retention to `.unlimited`",
        .tags(.lgp7)
    )
    func configurationWithRotationDefaultsToUnlimitedRetention() throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: rotation
        )
        #expect(configuration.retention == .unlimited)
    }

    @Test(
        "`Configuration(directory:rotation:retention:)` stores the explicit policy",
        .tags(.lgp7)
    )
    func configurationStoresExplicitRetentionPolicy() throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let retention = try RetentionPolicy.maxSegments(3)
        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: rotation,
            retention: retention
        )
        #expect(configuration.retention == retention)
    }
}

// MARK: - .unlimited no-op enforcement

extension FileLogStoreRetentionTests {
    @Test(
        "`.unlimited` retention deletes no segments across appends",
        .tags(.lgp7)
    )
    func unlimitedRetentionDeletesNoSegments() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(
                directory: directory,
                rotation: rotation,
                retention: .unlimited
            )
        )
        // Prove `.unlimited` preserves rotated topology and accepted bytes.
        let encoder = CanonicalEnvelopeLineEncoder()
        var expected: [(name: String, bytes: Data)] = []
        expected.reserveCapacity(5)
        for sequence: UInt64 in 1 ... 5 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence
            )
            let lineBytes = try encoder.encode(envelope)
            // Use production filename formatting for expected topology.
            let name = SegmentEnumeration.rotatedSegmentURL(
                in: directory, sequence: sequence, minimumWidth: 6
            ).lastPathComponent
            expected.append((name, lineBytes))
            try await store.append(envelope)
        }
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        #expect(names == expected.map(\.name))
        for entry in expected {
            let url = directory.appendingPathComponent(entry.name)
            let bytes = try Data(contentsOf: url)
            #expect(bytes == entry.bytes)
        }
    }

    @Test(
        "`.never` rotation + bounded retention is a no-op",
        .tags(.lgp7, .lgp25, .lgp27)
    )
    func neverRotationWithBoundedRetentionIsNoOp() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(
                directory: directory,
                rotation: .never,
                retention: try .maxSegments(1)
            )
        )
        var expectedBytes = Data()
        let encoder = CanonicalEnvelopeLineEncoder()
        for sequence: UInt64 in 1 ... 5 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence,
                payload: Data([0x01, 0x02, 0x03])
            )
            expectedBytes.append(try encoder.encode(envelope))
            try await store.append(envelope)
        }
        try await store.flush()

        let unrotated = directory.appendingPathComponent("log.ndjson")
        let bytes = try Data(contentsOf: unrotated)
        #expect(bytes == expectedBytes)

        let rotatedNames = try Self.rotatedSegmentNames(in: directory)
        #expect(rotatedNames.isEmpty)
    }

    @Test(
        "`.never` rotation + `.maxTotalBytes` is a no-op",
        .tags(.lgp7, .lgp25, .lgp27)
    )
    func neverRotationWithMaxTotalBytesIsNoOp() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(
            configuration: .init(
                directory: directory,
                rotation: .never,
                retention: try .maxTotalBytes(FileLogStore.maxEncodedLineBytes)
            )
        )
        var expectedBytes = Data()
        let encoder = CanonicalEnvelopeLineEncoder()
        for sequence: UInt64 in 1 ... 5 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(
                sequence: sequence,
                payload: Data([0x01, 0x02, 0x03])
            )
            expectedBytes.append(try encoder.encode(envelope))
            try await store.append(envelope)
        }
        try await store.flush()

        let unrotated = directory.appendingPathComponent("log.ndjson")
        let bytes = try Data(contentsOf: unrotated)
        #expect(bytes == expectedBytes)

        let rotatedNames = try Self.rotatedSegmentNames(in: directory)
        #expect(rotatedNames.isEmpty)
    }
}

// MARK: - .bySize maxSegments

extension FileLogStoreRetentionTests {
    @Test(
        "`.bySize` `.maxSegments` keeps newest N and deletes older rotated segments",
        .tags(.lgp7, .lgp25)
    )
    func bySizeMaxSegmentsKeepsNewestN() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(2)
        )
        // Four appends → four rotated segments; `.maxSegments(2)` keeps the two newest (3 + active 4).
        for sequence: UInt64 in 1 ... 4 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        #expect(names == ["log.000003.ndjson", "log.000004.ndjson"])
    }

    @Test(
        "`.bySize` `.maxSegments` never deletes the active writer segment",
        .tags(.lgp7, .lgp25)
    )
    func bySizeMaxSegmentsNeverDeletesActive() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(1)
        )
        for sequence: UInt64 in 1 ... 3 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        // After three appends the active segment is `log.000003`;
        // retention must drop older rotated segments and stop at
        // the active one.
        #expect(names == ["log.000003.ndjson"])
    }
}

// MARK: - .bySize maxTotalBytes

extension FileLogStoreRetentionTests {
    @Test(
        "`.bySize` `.maxTotalBytes` deletes oldest segments until total fits cap",
        .tags(.lgp7, .lgp25)
    )
    func bySizeMaxTotalBytesDeletesOldestUntilCapFits() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        // Cap = 2x encoded-line cap; each rotated segment holds one
        // ~1.07 MB line, so the fourth append drops the oldest.
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxTotalBytes(FileLogStore.maxEncodedLineBytes * 2)
        )
        for sequence: UInt64 in 1 ... 4 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        // Total before retention: ≈ 4.28 MB; cap = 4 MiB. Drop
        // oldest (≈ 1.07 MB) → remaining ≈ 3.21 MB ≤ cap.
        #expect(names == [
            "log.000002.ndjson",
            "log.000003.ndjson",
            "log.000004.ndjson"
        ])
    }

    @Test(
        "`.bySize` `.maxTotalBytes` stops deletion when only the active segment remains",
        .tags(.lgp7, .lgp25)
    )
    func bySizeMaxTotalBytesStopsAtActiveSegment() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        // Cap below two lines forces a deletion every append; the
        // loop stops at the active segment regardless of cap.
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxTotalBytes(FileLogStore.maxEncodedLineBytes)
        )
        for sequence: UInt64 in 1 ... 3 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        // Each append leaves only the freshest active segment.
        #expect(names == ["log.000003.ndjson"])
    }
}

// MARK: - Append cardinality

extension FileLogStoreRetentionTests {
    @Test(
        "Triggering append remains accepted even when retention deletes older segments",
        .tags(.lgp7, .lgp11, .lgp25, .lgp27)
    )
    func appendCardinalityPreservedAcrossRetention() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(2)
        )
        for sequence: UInt64 in 1 ... 4 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        // Triggering append (sequence 4) is active; sequence 3 is the
        // retained rotated segment. Bytes match the canonical encoder.
        let segment3 = directory.appendingPathComponent("log.000003.ndjson")
        let segment4 = directory.appendingPathComponent("log.000004.ndjson")
        #expect(try Data(contentsOf: segment3) == (try Self.encodedLine(for: 3)))
        #expect(try Data(contentsOf: segment4) == (try Self.encodedLine(for: 4)))
    }
}

// MARK: - Export interaction

extension FileLogStoreRetentionTests {
    @Test(
        "Export after retention is byte-stable over the retained segments only",
        .tags(.lgp7, .lgp8, .lgp32)
    )
    func exportAfterRetentionIsByteStableOverRetainedSegmentsOnly() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(2)
        )
        for sequence: UInt64 in 1 ... 4 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()

        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        let exportBytes = try Data(contentsOf: exportURL)
        let expected = try Self.encodedLine(for: 3) + Self.encodedLine(for: 4)
        // Export sees only `log.000003` and `log.000004` —
        // earlier segments were retention-deleted before export
        // ran.
        #expect(exportBytes == expected)
    }
}

// MARK: - Remove interaction

extension FileLogStoreRetentionTests {
    @Test(
        "removeExportedLogs after retention deletes a boundary segment fails .removalBoundaryStale",
        .tags(.lgp7, .lgp9)
    )
    func removeAfterRetentionDeletedBoundarySegmentFailsStale() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(2)
        )
        // Two appends keep both segments under the retention cap;
        // export captures a boundary referencing both.
        for sequence: UInt64 in 1 ... 2 {
            try await store.append(
                FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()
        let (exportURL, exportParent) = try Self.makeUniqueDestination()
        defer { FileLogStoreTestSupport.remove(exportParent) }
        try await store.exportLogs(to: exportURL)

        // Third append rotates and triggers retention to drop
        // segment 1 — the segment now named in the captured
        // export boundary.
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 3)
        )
        try await store.flush()
        let segment1 = directory.appendingPathComponent("log.000001.ndjson")
        #expect(!FileManager.default.fileExists(atPath: segment1.path))

        do {
            try await store.removeExportedLogs()
            Issue.record(
                "expected .removalBoundaryStale after retention-deleted boundary segment"
            )
        } catch {
            switch error {
            case .removalBoundaryStale:
                break
            default:
                Issue.record("unexpected remove error: \(error)")
            }
        }
    }
}

// MARK: - Retention failure injection

extension FileLogStoreRetentionTests {
    @Test(
        "Injected retention unlink failure surfaces .operationFailed(.enforceRetention) and preserves topology",
        .tags(.lgp2, .lgp7)
    )
    func injectedRetentionUnlinkFailureSurfacesEnforceRetentionError() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(1)
        )
        // First append admits sequence 1 and triggers no retention
        // (only one segment exists).
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        struct InjectedRetentionError: Error, Equatable {}
        // Second append admits, rotates, then retention's seam fails;
        // admission survives and caller sees `.operationFailed(.enforceRetention)`.
        try await Self.withRetentionUnlinkSeam(
            on: store,
            handler: { _ in throw InjectedRetentionError() },
            body: {
                do {
                    // `makeEnvelope` is untyped-throws and `append` is
                    // typed-throws on `FileLogStoreError`; the union is
                    // `any Error` so the catch needs an explicit cast to
                    // pattern-match the typed enum.
                    try await store.append(
                        FileLogStoreTestSupport.makeEnvelope(sequence: 2)
                    )
                    Issue.record("expected .operationFailed(.enforceRetention)")
                } catch let error as FileLogStoreError {
                    switch error {
                    case let .operationFailed(operation, url, _):
                        #expect(operation == .enforceRetention)
                        #expect(url.lastPathComponent == "log.000001.ndjson")
                    default:
                        Issue.record("unexpected append error: \(error)")
                    }
                } catch {
                    Issue.record("unexpected non-FileLogStoreError: \(error)")
                }
            }
        )
        // Topology is recoverable: the segment that retention
        // tried (and failed) to unlink remains; the admitted line
        // sits in the new active segment.
        let segment1 = directory.appendingPathComponent("log.000001.ndjson")
        let segment2 = directory.appendingPathComponent("log.000002.ndjson")
        #expect(FileManager.default.fileExists(atPath: segment1.path))
        #expect(try Data(contentsOf: segment1) == (try Self.encodedLine(for: 1)))
        let bytes2 = try Data(contentsOf: segment2)
        #expect(bytes2 == (try Self.encodedLine(for: 2)))

        // Follow-up append succeeds and proves later operations operate
        // on the recoverable topology left by the failed pass.
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 3)
        )
        try await store.flush()
        let names = try Self.rotatedSegmentNames(in: directory)
        // After the recovered append, retention drains earlier
        // segments down to the active one.
        #expect(names == ["log.000003.ndjson"])
    }
}

// MARK: - Candidate TOCTOU between seam and unlink

extension FileLogStoreRetentionTests {
    // swiftlint:disable function_body_length
    // Reason: Each TOCTOU proof co-locates rotation/retention/seam wiring, the planted swap, the typed-error catch, and the four post-failure topology assertions per RetentionPolicySQECoverage.md so the candidate-revalidation contract stays auditable in one body.

    @Test(
        "`.maxSegments` candidate swapped to a symlink between seam and unlink fails closed",
        .tags(.lgp2, .lgp7)
    )
    func maxSegmentsSymlinkSwapBetweenSeamAndUnlinkFailsClosed() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Sentinel target outside the store directory; the test
        // proves retention does not follow the planted symlink.
        let symlinkTargetParent = Self.uniqueDirectory()
        try Self.makeDirectory(symlinkTargetParent)
        defer { FileLogStoreTestSupport.remove(symlinkTargetParent) }
        let symlinkTarget = symlinkTargetParent.appendingPathComponent("target.bin")
        let targetBytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try targetBytes.write(to: symlinkTarget)

        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxSegments(1)
        )
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )

        // Replace segment 1 with an out-of-store symlink between selection
        // and unlink; post-seam revalidation must reject the now-non-regular candidate.
        try await Self.withRetentionUnlinkSeam(
            on: store,
            handler: { candidateURL in
                try FileManager.default.removeItem(at: candidateURL)
                try FileManager.default.createSymbolicLink(
                    at: candidateURL, withDestinationURL: symlinkTarget
                )
            },
            body: {
                do {
                    try await store.append(
                        FileLogStoreTestSupport.makeEnvelope(sequence: 2)
                    )
                    Issue.record("expected .operationFailed(.enforceRetention) for symlink swap")
                } catch let error as FileLogStoreError {
                    switch error {
                    case let .operationFailed(operation, url, _):
                        #expect(operation == .enforceRetention)
                        #expect(url.lastPathComponent == "log.000001.ndjson")
                    default:
                        Issue.record("unexpected append error: \(error)")
                    }
                } catch {
                    Issue.record("unexpected non-FileLogStoreError: \(error)")
                }
            }
        )

        // Triggering append (sequence 2) is admitted in the new
        // active segment.
        let segment2 = directory.appendingPathComponent("log.000002.ndjson")
        #expect(FileManager.default.fileExists(atPath: segment2.path))
        #expect(try Data(contentsOf: segment2) == (try Self.encodedLine(for: 2)))

        // Planted symlink stays in place — retention failed
        // closed without mutating the replacement entry.
        let symlinkURL = directory.appendingPathComponent("log.000001.ndjson")
        #expect(
            try FileManager.default.attributesOfItem(atPath: symlinkURL.path)[.type]
                as? FileAttributeType == .typeSymbolicLink
        )
        let resolved = try FileManager.default.destinationOfSymbolicLink(
            atPath: symlinkURL.path
        )
        #expect(resolved == symlinkTarget.path)

        // Symlink target bytes are unchanged — retention did not
        // follow the symlink.
        #expect(try Data(contentsOf: symlinkTarget) == targetBytes)
    }

    @Test(
        "`.maxTotalBytes` candidate swapped to a directory between seam and unlink fails closed",
        .tags(.lgp2, .lgp7)
    )
    func maxTotalBytesDirectorySwapBetweenSeamAndUnlinkFailsClosed() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let store = try Self.makeRotatingStore(
            directory: directory,
            retention: try .maxTotalBytes(FileLogStore.maxEncodedLineBytes)
        )
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )

        // Sentinel byte planted inside the directory replacement; a misbehaving retention pass would leave a detectable trace.
        let directoryReplacementSentinelByte: UInt8 = 0xA5

        // Seam: replace the regular candidate with a directory
        // (a non-regular entry of a different kind than the
        // symlink test). Post-seam revalidation must reject.
        try await Self.withRetentionUnlinkSeam(
            on: store,
            handler: { candidateURL in
                try FileManager.default.removeItem(at: candidateURL)
                try FileManager.default.createDirectory(
                    at: candidateURL, withIntermediateDirectories: false
                )
                // Plant a sentinel inside so the assertion below can
                // prove the directory-replacement entry survived.
                let sentinel = candidateURL.appendingPathComponent("sentinel.bin")
                try Data([directoryReplacementSentinelByte]).write(to: sentinel)
            },
            body: {
                do {
                    try await store.append(
                        FileLogStoreTestSupport.makeEnvelope(sequence: 2)
                    )
                    Issue.record(
                        "expected .operationFailed(.enforceRetention) for directory swap"
                    )
                } catch let error as FileLogStoreError {
                    switch error {
                    case let .operationFailed(operation, url, _):
                        #expect(operation == .enforceRetention)
                        #expect(url.lastPathComponent == "log.000001.ndjson")
                    default:
                        Issue.record("unexpected append error: \(error)")
                    }
                } catch {
                    Issue.record("unexpected non-FileLogStoreError: \(error)")
                }
            }
        )

        // Triggering append (sequence 2) is admitted in the new
        // active segment.
        let segment2 = directory.appendingPathComponent("log.000002.ndjson")
        #expect(FileManager.default.fileExists(atPath: segment2.path))
        #expect(try Data(contentsOf: segment2) == (try Self.encodedLine(for: 2)))

        // Planted directory replacement stays in place with its
        // sentinel intact — retention did not destroy or recurse
        // into the replacement.
        let directoryReplacement = directory.appendingPathComponent(
            "log.000001.ndjson"
        )
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directoryReplacement.path, isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
        let sentinelURL = directoryReplacement.appendingPathComponent(
            "sentinel.bin"
        )
        let sentinelBytes = try Data(contentsOf: sentinelURL)
        #expect(sentinelBytes == Data([directoryReplacementSentinelByte]))
    }

    // swiftlint:enable function_body_length
}

// MARK: - Descriptor-relative safety

extension FileLogStoreRetentionTests {
    @Test(
        "Configured-root swap after writer-root acquisition does not redirect retention",
        .tags(.lgp2, .lgp7)
    )
    func configuredRootSwapDoesNotRedirectRetention() async throws {
        let originalDirectory = Self.uniqueDirectory()
        try Self.makeDirectory(originalDirectory)
        defer { FileLogStoreTestSupport.remove(originalDirectory) }

        let store = try Self.makeRotatingStore(
            directory: originalDirectory,
            retention: try .maxSegments(1)
        )
        // First append acquires the writer-root descriptor on the
        // original directory's inode and produces segment 1.
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )

        // Rename the original directory aside; the held writer root still binds to the original inode.
        let renamedAside = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(renamedAside) }
        try FileManager.default.moveItem(
            at: originalDirectory, to: renamedAside
        )
        try Self.makeDirectory(originalDirectory)

        // Second append writes via held descriptor into the renamed-aside
        // directory; the new configured-path directory must remain empty.
        try await store.append(
            FileLogStoreTestSupport.makeEnvelope(sequence: 2)
        )
        try await store.flush()

        let renamedNames = try Self.rotatedSegmentNames(in: renamedAside)
        let originalPathNames = try Self.rotatedSegmentNames(in: originalDirectory)
        #expect(renamedNames == ["log.000002.ndjson"])
        #expect(originalPathNames.isEmpty)
    }
}
