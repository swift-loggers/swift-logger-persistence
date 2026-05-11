import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

// swiftlint:disable type_body_length
// Reason: LOCKED rotation SQE matrix kept in one type so the
// validation, configuration, topology, boundary, and rotated-segment
// close-failure proofs stay co-located for traceability.

@Suite("FileLogStore size-based rotation")
struct FileLogStoreRotationTests {
    // MARK: RotationPolicy validation

    @Test(
        "`RotationPolicy.bySize` rejects a zero segment cap",
        .tags(.lgp2, .lgp6)
    )
    func bySizeRejectsZeroSegmentCap() {
        do {
            _ = try RotationPolicy.bySize(maxSegmentBytes: 0)
            Issue.record("expected .invalidRotationPolicy for maxSegmentBytes = 0")
        } catch {
            #expect(error == .invalidRotationPolicy)
        }
    }

    @Test(
        "`RotationPolicy.bySize` rejects a negative segment cap",
        .tags(.lgp2, .lgp6)
    )
    func bySizeRejectsNegativeSegmentCap() {
        do {
            _ = try RotationPolicy.bySize(maxSegmentBytes: -1)
            Issue.record("expected .invalidRotationPolicy for negative cap")
        } catch {
            #expect(error == .invalidRotationPolicy)
        }
    }

    @Test(
        "`RotationPolicy.bySize` rejects a segment cap below the encoded-line cap",
        .tags(.lgp2, .lgp6)
    )
    func bySizeRejectsSegmentCapBelowEncodedLineCap() {
        do {
            _ = try RotationPolicy.bySize(
                maxSegmentBytes: FileLogStore.maxEncodedLineBytes - 1
            )
            Issue.record("expected .invalidRotationPolicy for cap < encoded-line cap")
        } catch {
            #expect(error == .invalidRotationPolicy)
        }
    }

    @Test(
        "`RotationPolicy.bySize` accepts a segment cap exactly at the encoded-line cap",
        .tags(.lgp6)
    )
    func bySizeAcceptsSegmentCapAtEncodedLineCap() throws {
        _ = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
    }

    // MARK: Configuration

    @Test(
        "`Configuration(directory:)` defaults to `RotationPolicy.never`",
        .tags(.lgp6)
    )
    func configurationDefaultsToNeverRotation() {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let configuration = FileLogStore.Configuration(directory: directory)
        #expect(configuration.rotation == .never)
    }

    @Test(
        "`Configuration(directory:rotation:)` stores the explicit policy",
        .tags(.lgp6)
    )
    func configurationStoresExplicitRotationPolicy() throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let configuration = FileLogStore.Configuration(
            directory: directory,
            rotation: policy
        )
        #expect(configuration.rotation == policy)
    }

    // MARK: Filename topology per policy

    @Test(
        "`.never` writes every line into the unrotated `log.ndjson` filename",
        .tags(.lgp6)
    )
    func neverRotationWritesAllLinesToUnrotatedFilename() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        for sequence in 1 ... 3 {
            try await store.append(try FileLogStoreTestSupport.makeEnvelope(
                sequence: UInt64(sequence),
                payload: Data([0x01, 0x02, 0x03])
            ))
        }
        try await store.flush()
        let unrotated = directory.appendingPathComponent("log.ndjson")
        #expect(FileManager.default.fileExists(atPath: unrotated.path))
        let rotated = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1)
        #expect(!FileManager.default.fileExists(atPath: rotated.path))
    }

    @Test(
        "`.bySize` writes the first segment as `log.000001.ndjson`",
        .tags(.lgp6, .lgp39)
    )
    func bySizeFirstSegmentIsZeroPaddedSequenceOne() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1,
            payload: Data([0x01, 0x02, 0x03])
        ))
        try await store.flush()
        let segment = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1)
        #expect(FileManager.default.fileExists(atPath: segment.path))
        let unrotated = directory.appendingPathComponent("log.ndjson")
        #expect(!FileManager.default.fileExists(atPath: unrotated.path))
    }

    // MARK: Boundary rotation

    @Test(
        "An admitted line that fits the segment exactly does not rotate",
        .tags(.lgp6, .lgp39)
    )
    func bySizeRotationDoesNotTriggerWhenLineExactlyFillsRemainingCap() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let policy = try RotationPolicy.bySize(maxSegmentBytes: lineSize * 2)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(sequence: 1))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(sequence: 2))
        try await store.flush()
        let segment1 = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1)
        let segment2 = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 2)
        let bytes1 = try Data(contentsOf: segment1)
        #expect(bytes1.count == 2 * lineSize)
        #expect(!FileManager.default.fileExists(atPath: segment2.path))
    }

    @Test(
        "Rotation triggers when the next admitted line would exceed the segment cap",
        .tags(.lgp6, .lgp39)
    )
    func bySizeRotationCrossesSegmentAtExactBoundary() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let maxSegmentBytes = lineSize * 2
        let policy = try RotationPolicy.bySize(maxSegmentBytes: maxSegmentBytes)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        for sequence in 1 ... 3 {
            try await store.append(try FileLogStoreTestSupport.makeEnvelope(sequence: UInt64(sequence)))
        }
        try await store.flush()
        let segment1 = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1)
        let segment2 = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 2)
        let segment3 = FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 3)
        let bytes1 = try Data(contentsOf: segment1)
        let bytes2 = try Data(contentsOf: segment2)
        #expect(bytes1.count == 2 * lineSize)
        #expect(bytes2.count == lineSize)
        #expect(!FileManager.default.fileExists(atPath: segment3.path))
    }

    @Test(
        "Rotation closes the previous segment with its trailing LF intact",
        .tags(.lgp26, .lgp27, .lgp39)
    )
    func bySizeRotationLeavesPreviousSegmentLFStable() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let policy = try RotationPolicy.bySize(maxSegmentBytes: lineSize * 2)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(sequence: 2)
        try await store.append(envelope1)
        try await store.append(envelope2)
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(sequence: 3))
        try await store.flush()
        let bytes1 = try Data(contentsOf: FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1))
        let line1 = try CanonicalEnvelopeLineEncoder().encode(envelope1)
        let line2 = try CanonicalEnvelopeLineEncoder().encode(envelope2)
        #expect(bytes1 == line1 + line2)
        #expect(bytes1.last == 0x0A)
    }

    @Test(
        "Rotation places the rotating append as one full canonical line in the new segment",
        .tags(.lgp26, .lgp39)
    )
    func bySizeRotationStartsNewSegmentWithFullCanonicalLine() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let policy = try RotationPolicy.bySize(maxSegmentBytes: lineSize * 2)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(sequence: 2)
        let envelope3 = try FileLogStoreTestSupport.makeEnvelope(sequence: 3)
        try await store.append(envelope1)
        try await store.append(envelope2)
        try await store.append(envelope3)
        try await store.flush()
        let bytes2 = try Data(contentsOf: FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 2))
        let line3 = try CanonicalEnvelopeLineEncoder().encode(envelope3)
        #expect(bytes2 == line3)
        #expect(bytes2.last == 0x0A)
    }

    @Test(
        "Rotation never splits an accepted line across two segments",
        .tags(.lgp26, .lgp27, .lgp39)
    )
    func bySizeRotationDoesNotSplitLineAcrossSegments() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let policy = try RotationPolicy.bySize(maxSegmentBytes: lineSize * 2)
        let store = FileLogStore(configuration: .init(
            directory: directory,
            rotation: policy
        ))
        var envelopes: [PersistentLogEnvelope] = []
        for sequence in 1 ... 5 {
            let envelope = try FileLogStoreTestSupport.makeEnvelope(sequence: UInt64(sequence))
            envelopes.append(envelope)
            try await store.append(envelope)
        }
        try await store.flush()
        let firstSegment = try Data(contentsOf: FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 1))
        let secondSegment = try Data(contentsOf: FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 2))
        let thirdSegment = try Data(contentsOf: FileLogStoreTestSupport.rotatedSegmentURL(in: directory, sequence: 3))
        #expect(firstSegment.first != 0x0A)
        #expect(secondSegment.first != 0x0A)
        #expect(thirdSegment.first != 0x0A)
        #expect(firstSegment.last == 0x0A)
        #expect(secondSegment.last == 0x0A)
        #expect(thirdSegment.last == 0x0A)
        let encoder = CanonicalEnvelopeLineEncoder()
        let expected = try envelopes.map { try encoder.encode($0) }
        #expect(firstSegment == expected[0] + expected[1])
        #expect(secondSegment == expected[2] + expected[3])
        #expect(thirdSegment == expected[4])
    }

    // MARK: Rotated-segment close failure

    @Test(
        "Rotation close failure surfaces .closeWritableSegment, admits no bytes, leaves new active recoverable",
        .tags(.lgp2, .lgp6)
    )
    func rotationCloseFailureSurfacesCloseWritableSegment() async throws {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }
        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(
            configuration: .init(directory: directory, rotation: rotation)
        )
        let encoder = CanonicalEnvelopeLineEncoder()
        let envelope1 = try FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        let envelope2 = try FileLogStoreTestSupport.makeEnvelope(sequence: 2)
        let envelope3 = try FileLogStoreTestSupport.makeEnvelope(sequence: 3)
        let encoded1 = try encoder.encode(envelope1)
        let encoded3 = try encoder.encode(envelope3)

        // First append fills log.000001 to the rotation cap; the
        // next append must rotate.
        try await store.append(envelope1)

        struct InjectedRotationCloseError: Error {}
        try await Self.withRotatedSegmentCloseSeam(
            on: store,
            handler: { _ in throw InjectedRotationCloseError() },
            body: {
                do {
                    try await store.append(envelope2)
                    Issue.record("expected .operationFailed(.closeWritableSegment)")
                } catch let error as FileLogStoreError {
                    switch error {
                    case let .operationFailed(operation, url, _):
                        #expect(operation == .closeWritableSegment)
                        #expect(url.lastPathComponent == "log.000001.ndjson")
                    default:
                        Issue.record("unexpected append error: \(error)")
                    }
                } catch {
                    Issue.record("unexpected non-FileLogStoreError: \(error)")
                }
            }
        )

        // log.000002 already exists as the post-rotation active
        // segment but holds no admitted bytes — envelope 2 never
        // reached storage because rotation projected close failure
        // before the write step.
        let segment1 = directory.appendingPathComponent("log.000001.ndjson")
        let segment2 = directory.appendingPathComponent("log.000002.ndjson")
        #expect(FileManager.default.fileExists(atPath: segment2.path))
        #expect(try Data(contentsOf: segment2).isEmpty)

        // Recovery: a follow-up append writes envelope 3's canonical
        // bytes into log.000002 — the post-failure active state is
        // deterministic and reusable.
        try await store.append(envelope3)
        try await store.flush()
        #expect(try Data(contentsOf: segment2) == encoded3)

        // The pre-rotation segment retains envelope 1's canonical
        // bytes byte-for-byte; the failed close did not mutate it.
        #expect(try Data(contentsOf: segment1) == encoded1)
    }

    /// Runs `body` with a rotated-close seam handler installed and
    /// clears the seam before returning, even when `body` throws.
    private static func withRotatedSegmentCloseSeam(
        on store: FileLogStore,
        handler: @Sendable @escaping (URL) throws -> Void,
        body: () async throws -> Void
    ) async throws {
        await store._setOnBeforeRotatedSegmentCloseForTesting(handler)
        var capturedError: (any Error)?
        do {
            try await body()
        } catch {
            capturedError = error
        }
        await store._setOnBeforeRotatedSegmentCloseForTesting(nil)
        if let capturedError { throw capturedError }
    }
}

// swiftlint:enable type_body_length
