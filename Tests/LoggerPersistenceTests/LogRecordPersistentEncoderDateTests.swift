import Foundation
import Loggers
import Testing

@testable import LoggerPersistence

/// Date-representability and envelope-validation propagation tests
/// for `LogRecordPersistentEncoder`.
@Suite("LogRecordPersistentEncoder date and envelope validation")
struct LogRecordPersistentEncoderDateTests {
    private static func makeRecord(
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        level: LoggerLevel = .info,
        domain: LoggerDomain = "Auth",
        message: LogMessage = "ok",
        attributes: [LogAttribute] = []
    ) -> LogRecord {
        LogRecord(
            timestamp: timestamp,
            level: level,
            domain: domain,
            message: message,
            attributes: attributes
        )
    }

    // MARK: Date representability

    @Test("Encoder rejects records whose timestamp is non-representable")
    func nonRepresentableTimestampIsRejected() throws {
        // Non-finite timestamps must fail closed instead of producing
        // canonical RFC 3339 bytes.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(timestamp: Date(timeIntervalSince1970: .nan))
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects LogValue.date attributes that are non-representable")
    func nonRepresentableLogValueDateIsRejected() throws {
        // Non-finite `LogValue.date` attributes follow the same
        // representability contract as `record.timestamp`.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            attributes: [LogAttribute("when", .date(Date(timeIntervalSince1970: .nan)))]
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects record.timestamp with year above the RFC 3339 four-digit range")
    func recordTimestampYearOverflowIsRejected() throws {
        // Dates outside RFC 3339 four-digit AD years must fail before rendering.
        let encoder = LogRecordPersistentEncoder()
        let farFuture = Date(timeIntervalSinceReferenceDate: 1_000_000_000_000)
        let record = Self.makeRecord(timestamp: farFuture)
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects record.timestamp with year before the RFC 3339 four-digit range")
    func recordTimestampYearUnderflowIsRejected() throws {
        // BCE dates are outside the canonical RFC 3339 AD year range.
        let encoder = LogRecordPersistentEncoder()
        let farPast = Date(timeIntervalSinceReferenceDate: -1_000_000_000_000)
        let record = Self.makeRecord(timestamp: farPast)
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects LogValue.date attributes with year outside the RFC 3339 range")
    func logValueDateYearOutOfRangeIsRejected() throws {
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            attributes: [
                LogAttribute(
                    "when",
                    .date(Date(timeIntervalSinceReferenceDate: 1_000_000_000_000))
                )
            ]
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects sub-millisecond record.timestamp with nonRepresentableDate")
    func subMillisecondTimestampIsRejected() throws {
        // The canonical RFC 3339 millisecond profile rejects
        // non-millisecond-aligned values instead of truncating them
        // into canonical millisecond bytes.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456)
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects single-microsecond sub-ms record.timestamp")
    func singleMicrosecondSubMillisecondTimestampIsRejected() throws {
        // Regression coverage for values close to the millisecond
        // boundary; non-millisecond-aligned timestamps must fail closed.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123_001)
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects sub-millisecond LogValue.date attributes with nonRepresentableDate")
    func subMillisecondLogValueDateIsRejected() throws {
        // `LogValue.date` attributes follow the same canonical
        // millisecond-alignment rules as `record.timestamp`.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            attributes: [
                LogAttribute(
                    "when",
                    .date(Date(timeIntervalSince1970: 1_700_000_000.123456))
                )
            ]
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder rejects pre-epoch sub-millisecond record.timestamp with nonRepresentableDate")
    func preEpochSubMillisecondTimestampIsRejected() throws {
        // Negative intervals follow the same millisecond-alignment rejection path.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            timestamp: Date(timeIntervalSinceReferenceDate: -12345.678901)
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder emits canonical millisecond timestamp for ms-aligned record.timestamp")
    func canonicalMillisecondTimestampEmitted() throws {
        // Millisecond-aligned timestamps preserve their canonical
        // RFC 3339 rendering exactly.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        let envelope = try encoder.encode(record)
        let payload = try payloadString(envelope)
        #expect(payload.contains(#""timestamp":"2023-11-14T22:13:20.123Z""#))
    }

    @Test("Encoder rejects sub-ms record.timestamp at year 9999 with nonRepresentableDate")
    func year9999SubMillisecondTimestampRejected() throws {
        // Year-9999 sub-millisecond values must fail closed instead
        // of being rounded into canonical millisecond bytes.
        guard let timestamp = Year9999DateFixture.lastSecond(
            millisecond: 123,
            microsecondOffset: 100
        ) else {
            Issue.record("could not construct year-9999 sub-ms timestamp")
            return
        }
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(timestamp: timestamp)
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    @Test("Encoder emits canonical ms timestamp for ms-aligned record.timestamp at year 9999")
    func year9999MillisecondAlignedTimestampEmitted() throws {
        // Millisecond-aligned year-9999 timestamps remain representable.
        guard let timestamp = Year9999DateFixture.lastSecond(millisecond: 123) else {
            Issue.record("could not construct year-9999 ms-aligned timestamp")
            return
        }
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(timestamp: timestamp)
        let envelope = try encoder.encode(record)
        let payload = try payloadString(envelope)
        #expect(payload.contains(#""timestamp":"9999-12-31T23:59:59.123Z""#))
    }

    @Test("Encoder rejects LogValue.date attributes with infinite time interval")
    func infiniteLogValueDateIsRejected() throws {
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(
            attributes: [LogAttribute("when", .date(Date(timeIntervalSince1970: .infinity)))]
        )
        #expect(throws: LogRecordPersistentEncoderError.nonRepresentableDate) {
            try encoder.encode(record)
        }
    }

    // MARK: Envelope validation propagation

    @Test("Encoder propagates envelope validation failures via .invalidEnvelope")
    func encoderPropagatesEnvelopeValidationError() throws {
        // Envelope validation failures propagate through the encoder's
        // typed error surface unchanged.
        let encoder = LogRecordPersistentEncoder()
        let record = Self.makeRecord(domain: LoggerDomain("Auth\u{01}"))
        #expect(
            throws: LogRecordPersistentEncoderError.invalidEnvelope(
                .invalidHintValueControlCharacter(key: "domain")
            )
        ) {
            try encoder.encode(record)
        }
    }
}
