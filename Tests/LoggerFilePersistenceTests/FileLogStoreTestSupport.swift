import Foundation
import LoggerPersistence

@testable import LoggerFilePersistence

enum FileLogStoreTestSupport {
    static let baselineId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )

    /// Payload size for rotation tests, sized to produce a
    /// canonical envelope line near the policy minimum.
    static let rotationPayloadSize = 800_000

    static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerFilePersistenceTests")
            .appendingPathComponent(UUID().uuidString)
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func rotationPayload() -> Data {
        // Stable base64 payload for deterministic line-size tests.
        Data(repeating: 0x41, count: rotationPayloadSize)
    }

    static func makeEnvelope(
        sequence: UInt64,
        payload: Data = rotationPayload(),
        contentType: String = "application/vnd.test.v1+json"
    ) throws -> PersistentLogEnvelope {
        try PersistentLogEnvelope(
            id: baselineId,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: contentType,
            hints: [:],
            payload: payload
        )
    }

    static func encodedLineSize(
        for envelope: PersistentLogEnvelope
    ) throws -> Int {
        try CanonicalEnvelopeLineEncoder().encode(envelope).count
    }

    static func rotatedSegmentURL(
        in directory: URL,
        sequence: UInt64
    ) -> URL {
        SegmentEnumeration.rotatedSegmentURL(
            in: directory,
            sequence: sequence
        )
    }
}
