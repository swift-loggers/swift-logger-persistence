import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@Suite("PersistentLogEnvelope")
struct PersistentLogEnvelopeTests {
    /// Deterministic UUID fixtures for envelope construction.
    private static let baselineId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )
    private static let alternateId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
    )

    private static func makeEnvelope(
        id: UUID = baselineId,
        sequence: UInt64 = 1,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        contentType: String = "application/vnd.test.v1+json",
        hints: [String: String] = ["level": "info", "domain": "auth"],
        payload: Data = Data([0x01, 0x02, 0x03])
    ) throws -> PersistentLogEnvelope {
        try PersistentLogEnvelope(
            id: id,
            sequence: sequence,
            createdAt: timestamp,
            contentType: contentType,
            hints: hints,
            payload: payload
        )
    }

    // MARK: Equatable

    @Test("Two envelopes with identical fields are equal")
    func identicalEnvelopesAreEqual() throws {
        let lhs = try Self.makeEnvelope()
        let rhs = try Self.makeEnvelope()
        #expect(lhs == rhs)
    }

    @Test(
        "Envelopes that differ in any single field are not equal",
        arguments: [
            "id",
            "sequence",
            "createdAt",
            "contentType",
            "hints",
            "payload"
        ]
    )
    func differingFieldsAreNotEqual(field: String) throws {
        let baseline = try Self.makeEnvelope()
        let mutated: PersistentLogEnvelope
        switch field {
        case "id":
            mutated = try Self.makeEnvelope(id: Self.alternateId)
        case "sequence":
            mutated = try Self.makeEnvelope(sequence: 2)
        case "createdAt":
            mutated = try Self.makeEnvelope(timestamp: Date(timeIntervalSince1970: 1_700_000_001))
        case "contentType":
            mutated = try Self.makeEnvelope(contentType: "application/vnd.different.v1+json")
        case "hints":
            mutated = try Self.makeEnvelope(hints: ["level": "error"])
        case "payload":
            mutated = try Self.makeEnvelope(payload: Data([0x09, 0x08, 0x07]))
        default:
            // Test arguments are a closed list above; an unhandled
            // field signals the list and the switch drifted.
            Issue.record("unhandled field \(field) in differingFieldsAreNotEqual")
            return
        }
        #expect(baseline != mutated)
    }

    // MARK: Positive construction

    @Test("Valid envelope construction succeeds and exposes properties verbatim")
    func validConstructionSucceedsAndExposesProperties() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let envelope = try PersistentLogEnvelope(
            id: Self.baselineId,
            sequence: 7,
            createdAt: timestamp,
            contentType: "application/vnd.test.v1+json",
            hints: ["a": "1", "b": "2"],
            payload: payload
        )
        #expect(envelope.id == Self.baselineId)
        #expect(envelope.sequence == 7)
        #expect(envelope.createdAt == timestamp)
        #expect(envelope.contentType == "application/vnd.test.v1+json")
        #expect(envelope.hints == ["a": "1", "b": "2"])
        #expect(envelope.payload == payload)
    }
}

extension PersistentLogEnvelopeTests {
    // MARK: Negative construction

    @Test(
        "Public construction rejects sequence 0 with invalidSequence",
        .tags(.lgp2, .lgp38)
    )
    func zeroSequenceIsRejected() {
        #expect(throws: PersistentLogEnvelopeValidationError.invalidSequence) {
            try Self.makeEnvelope(sequence: 0)
        }
    }

    @Test(
        "Public construction rejects createdAt that the canonical encoder would not render",
        arguments: [
            // Non-finite intervals.
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity),
            // Far-future: outside the canonical four-digit AD year range.
            Date(timeIntervalSinceReferenceDate: 1_000_000_000_000),
            // Far-past: BCE dates are outside the canonical AD era.
            Date(timeIntervalSinceReferenceDate: -1_000_000_000_000),
            // Non-millisecond-aligned values are rejected instead
            // of rounded/truncated.
            Date(timeIntervalSince1970: 1_700_000_000.123456),
            Date(timeIntervalSinceReferenceDate: -12345.678901)
        ]
    )
    func invalidCreatedAtIsRejected(timestamp: Date) {
        #expect(throws: PersistentLogEnvelopeValidationError.invalidCreatedAt) {
            try Self.makeEnvelope(timestamp: timestamp)
        }
    }

    @Test(
        "Public construction accepts ms-aligned createdAt at year 9999 (high-magnitude)",
        .tags(.lgp21)
    )
    func millisecondAlignedYear9999CreatedAtAccepted() throws {
        guard let timestamp = Year9999DateFixture.lastSecond(millisecond: 123) else {
            Issue.record("could not construct year-9999 ms-aligned timestamp")
            return
        }
        let envelope = try Self.makeEnvelope(timestamp: timestamp)
        #expect(envelope.createdAt == timestamp)
    }

    @Test(
        "Public construction rejects sub-ms createdAt at year 9999 (high-magnitude)",
        .tags(.lgp2, .lgp38)
    )
    func subMillisecondYear9999CreatedAtRejected() {
        // Year-9999 sub-millisecond values must fail closed instead
        // of being rounded into canonical millisecond bytes.
        guard let timestamp = Year9999DateFixture.lastSecond(
            millisecond: 123,
            microsecondOffset: 100
        ) else {
            Issue.record("could not construct year-9999 sub-ms timestamp")
            return
        }
        #expect(throws: PersistentLogEnvelopeValidationError.invalidCreatedAt) {
            try Self.makeEnvelope(timestamp: timestamp)
        }
    }

    @Test(
        "Public construction accepts millisecond-aligned createdAt (post- and pre-epoch)",
        arguments: [
            // Whole-second post-epoch.
            Date(timeIntervalSince1970: 1_700_000_000),
            // Millisecond-aligned post-epoch.
            Date(timeIntervalSince1970: 1_700_000_000.123),
            // Whole-second pre-reference (negative interval).
            Date(timeIntervalSinceReferenceDate: -12345),
            // Millisecond-aligned negative intervals remain representable.
            Date(timeIntervalSinceReferenceDate: -12345.678)
        ]
    )
    func millisecondAlignedCreatedAtAccepted(timestamp: Date) throws {
        let envelope = try Self.makeEnvelope(timestamp: timestamp)
        #expect(envelope.createdAt == timestamp)
    }

    @Test(
        "Public construction rejects invalid contentType with invalidContentType",
        arguments: [
            // Empty string.
            "",
            // ASCII control character (NUL).
            "application/json\u{00}",
            // Whitespace inside the value.
            "application/json json",
            // Non-ASCII bytes are outside the visible-ASCII content-type profile.
            "application/json\u{00E9}",
            // Exceeds the 128-byte limit.
            String(repeating: "a", count: 129)
        ]
    )
    func invalidContentTypeIsRejected(value: String) {
        #expect(throws: PersistentLogEnvelopeValidationError.invalidContentType) {
            try Self.makeEnvelope(contentType: value)
        }
    }

    @Test(
        "Public construction accepts any visible-ASCII contentType within the length cap",
        arguments: [
            // Package-owned JSON payload media types.
            "application/json",
            "application/vnd.swift-logger.record-redacted.v1+json",
            "application/vnd.test.v1+json",
            "application/hal+json",
            // Non-JSON media types are also accepted at the envelope
            // boundary; the JSON-payload media-type rule is a
            // producer-side constraint, not an envelope-level one.
            "application/octet-stream",
            "application/vnd.test.v1",
            "text/plain"
        ]
    )
    func validContentTypeIsAccepted(value: String) throws {
        let envelope = try Self.makeEnvelope(contentType: value)
        #expect(envelope.contentType == value)
    }

    @Test(
        "Public construction rejects more than 16 hint entries with tooManyHints",
        .tags(.lgp2, .lgp22, .lgp38)
    )
    func tooManyHintsIsRejected() {
        var hints: [String: String] = [:]
        for index in 0 ..< 17 {
            hints["k\(index)"] = "v"
        }
        #expect(
            throws: PersistentLogEnvelopeValidationError.tooManyHints(limit: 16, actual: 17)
        ) {
            try Self.makeEnvelope(hints: hints)
        }
    }

    @Test(
        "Public construction rejects invalid hint keys with invalidHintKey",
        arguments: [
            "",
            "key with space",
            "colon:not:allowed",
            String(repeating: "k", count: 129)
        ]
    )
    func invalidHintKeyIsRejected(key: String) {
        #expect(throws: PersistentLogEnvelopeValidationError.invalidHintKey(key: key)) {
            try Self.makeEnvelope(hints: [key: "value"])
        }
    }

    @Test(
        "Public construction rejects too-long hint value with hintValueTooLong",
        .tags(.lgp2, .lgp22, .lgp38)
    )
    func tooLongHintValueIsRejected() {
        let oversize = String(repeating: "a", count: 513)
        #expect(
            throws: PersistentLogEnvelopeValidationError.hintValueTooLong(
                key: "k",
                limitBytes: 512,
                actualBytes: 513
            )
        ) {
            try Self.makeEnvelope(hints: ["k": oversize])
        }
    }

    @Test(
        "Public construction rejects hint value control characters",
        .tags(.lgp2, .lgp38)
    )
    func hintValueControlCharacterIsRejected() {
        // 0x01 inside the value -- ASCII control (Start of Heading).
        #expect(
            throws: PersistentLogEnvelopeValidationError.invalidHintValueControlCharacter(
                key: "k"
            )
        ) {
            try Self.makeEnvelope(hints: ["k": "before\u{01}after"])
        }
        // 0x7F (DEL) is also a control character in this profile.
        #expect(
            throws: PersistentLogEnvelopeValidationError.invalidHintValueControlCharacter(
                key: "k"
            )
        ) {
            try Self.makeEnvelope(hints: ["k": "del\u{7F}"])
        }
    }

    @Test(
        "Public construction rejects raw payload over 1 MiB with rawPayloadTooLarge",
        .tags(.lgp2, .lgp22, .lgp38)
    )
    func payloadOverLimitIsRejected() {
        let oversize = Data(count: 1_048_577)
        #expect(
            throws: PersistentLogEnvelopeValidationError.rawPayloadTooLarge(
                limitBytes: 1_048_576,
                actualBytes: 1_048_577
            )
        ) {
            try Self.makeEnvelope(payload: oversize)
        }
    }

    @Test(
        "Public construction reports the lexicographically first failing hint key",
        .tags(.lgp38)
    )
    func hintKeyValidationUsesLexFirstAcrossAllKeys() {
        // Validation reports the first invalid key in UTF-8 byte order.
        #expect(
            throws: PersistentLogEnvelopeValidationError.invalidHintKey(key: "bad:1")
        ) {
            try Self.makeEnvelope(hints: ["bad:1": "v", "bad:2": "v"])
        }
    }

    @Test(
        "Public construction reports the lexicographically first too-long hint value key",
        .tags(.lgp38)
    )
    func hintValueLengthValidationUsesLexFirstAcrossAllKeys() {
        // Validation reports the first failing key in UTF-8 byte
        // order, independent of `Dictionary` iteration order.
        let oversize = String(repeating: "x", count: 513)
        #expect(
            throws: PersistentLogEnvelopeValidationError.hintValueTooLong(
                key: "aaa",
                limitBytes: 512,
                actualBytes: 513
            )
        ) {
            try Self.makeEnvelope(hints: [
                "aaa": oversize,
                "bbb": oversize,
                "ccc": oversize
            ])
        }
    }

    @Test(
        "Public construction reports the lexicographically first hint value control-char key",
        .tags(.lgp38)
    )
    func hintValueControlCharacterValidationUsesLexFirstAcrossAllKeys() {
        // Validation reports the first failing key in UTF-8 byte
        // order, independent of `Dictionary` iteration order.
        #expect(
            throws: PersistentLogEnvelopeValidationError.invalidHintValueControlCharacter(
                key: "aaa"
            )
        ) {
            try Self.makeEnvelope(hints: [
                "aaa": "x\u{01}y",
                "bbb": "x\u{01}y",
                "ccc": "x\u{01}y"
            ])
        }
    }
}
