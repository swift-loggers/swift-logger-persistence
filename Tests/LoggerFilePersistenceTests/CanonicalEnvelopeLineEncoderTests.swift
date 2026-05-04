import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Canonical envelope-line encoder coverage.
@Suite("CanonicalEnvelopeLineEncoder canonical wire format")
struct CanonicalEnvelopeLineEncoderTests {
    private static let baselineId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )

    private static func makeEnvelope(
        sequence: UInt64 = 1,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        contentType: String = "application/vnd.test.v1+json",
        hints: [String: String] = [:],
        payload: Data = Data([0x01, 0x02, 0x03])
    ) throws -> PersistentLogEnvelope {
        try PersistentLogEnvelope(
            id: baselineId,
            sequence: sequence,
            createdAt: timestamp,
            contentType: contentType,
            hints: hints,
            payload: payload
        )
    }

    private static func encodedString(_ envelope: PersistentLogEnvelope) throws -> String {
        let bytes = try CanonicalEnvelopeLineEncoder().encode(envelope)
        return try #require(String(data: bytes, encoding: .utf8))
    }

    @Test(
        "Encoder emits canonical top-level keys in UTF-8 byte order with LF terminator",
        .tags(.lgp21, .lgp26)
    )
    func canonicalTopLevelKeyOrderAndLineTerminator() throws {
        let envelope = try Self.makeEnvelope(
            hints: ["level": "info", "domain": "auth"]
        )
        let line = try Self.encodedString(envelope)
        let expected = ##"{"contentType":"application\/vnd.test.v1+json","## +
            ##""createdAt":"2023-11-14T22:13:20.000Z","## +
            ##""hints":{"domain":"auth","level":"info"},"## +
            ##""id":"00000000-0000-0000-0000-000000000001","## +
            ##""payload":"AQID","sequence":1}"## + "\n"
        #expect(line == expected)
    }

    @Test(
        "Encoder escapes solidus inside string values as `\\/`",
        .tags(.lgp21)
    )
    func solidusEscapingInsideStringValues() throws {
        let envelope = try Self.makeEnvelope(contentType: "application/json")
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""contentType":"application\/json""##))
    }

    @Test(
        "Encoder escapes the canonical solidus, backslash, and quote in hint values",
        .tags(.lgp21)
    )
    func canonicalEscapeTableForHintValues() throws {
        let envelope = try Self.makeEnvelope(hints: [
            "slash": "a/b",
            "backslash": "a\\b",
            "quote": "a\"b"
        ])
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""slash":"a\/b""##))
        #expect(line.contains(##""backslash":"a\\b""##))
        #expect(line.contains(##""quote":"a\"b""##))
    }

    @Test(
        "Encoder emits non-ASCII scalars as UTF-8 bytes, not `\\u` escapes",
        .tags(.lgp21)
    )
    func nonASCIIEmittedAsUTF8Bytes() throws {
        // Keep source ASCII while exercising non-ASCII UTF-8 output.
        let value = "caf\u{e9}"
        let envelope = try Self.makeEnvelope(hints: ["key": value])
        let line = try Self.encodedString(envelope)
        #expect(line.contains("\"key\":\"" + value + "\""))
        // Canonical bytes must contain UTF-8, not `\u` escapes.
        // Reject the unicode escape spelling case-insensitively so
        // both lowercase and uppercase escape spellings are caught.
        #expect(line.range(of: ##"\u00e9"##, options: .caseInsensitive) == nil)
    }

    @Test(
        "Encoder emits id in canonical lower-case `8-4-4-4-12` form",
        .tags(.lgp21)
    )
    func uuidEmittedInCanonicalLowerCaseForm() throws {
        let mixedCaseInputId = UUID(
            uuid: (
                0xAB, 0xCD, 0xEF, 0x01,
                0x23, 0x45,
                0x67, 0x89,
                0x9A, 0xBC,
                0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78
            )
        )
        let envelope = try PersistentLogEnvelope(
            id: mixedCaseInputId,
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.test.v1+json",
            hints: [:],
            payload: Data()
        )
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""id":"abcdef01-2345-6789-9abc-def012345678""##))
    }

    @Test(
        "Encoder emits empty hints object as `{}`",
        .tags(.lgp21)
    )
    func emptyHintsObjectShape() throws {
        let envelope = try Self.makeEnvelope(hints: [:])
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""hints":{}"##))
    }

    @Test(
        "Encoder sorts hint keys by UTF-8 byte order, not insertion order",
        .tags(.lgp21)
    )
    func hintKeysSortedByUTF8ByteOrder() throws {
        let envelope = try Self.makeEnvelope(
            hints: ["zeta": "z", "alpha": "a", "middle": "m"]
        )
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""hints":{"alpha":"a","middle":"m","zeta":"z"}"##))
    }

    @Test(
        "Encoder emits payload as standard base64 with padding",
        .tags(.lgp21)
    )
    func payloadEmittedAsStandardBase64() throws {
        // Known base64 fixture.
        let envelope = try Self.makeEnvelope(payload: Data("Hello".utf8))
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""payload":"SGVsbG8=""##))
    }

    @Test(
        "Encoder escapes the standard base64 alphabet's solidus inside the payload field",
        .tags(.lgp21)
    )
    func payloadBase64SolidusIsEscaped() throws {
        // `0xFF 0xFF 0xFF` encodes to `////`; canonical JSON escapes `/`.
        let envelope = try Self.makeEnvelope(payload: Data([0xFF, 0xFF, 0xFF]))
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""payload":"\/\/\/\/""##))
    }

    @Test(
        "Encoder emits sequence as a JSON number, not a string",
        .tags(.lgp21)
    )
    func sequenceEmittedAsJSONNumber() throws {
        let envelope = try Self.makeEnvelope(sequence: 42)
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""sequence":42"##))
    }

    @Test(
        "Encoder emits createdAt with fixed millisecond fractional precision",
        .tags(.lgp21)
    )
    func createdAtRendersWithFixedMillisecondPrecision() throws {
        let envelope = try Self.makeEnvelope(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""createdAt":"2023-11-14T22:13:20.123Z""##))
    }

    @Test(
        "Encoder produces only one LF in the encoded line, at the very end",
        .tags(.lgp21, .lgp26)
    )
    func encodedLineHasSingleTrailingLF() throws {
        let envelope = try Self.makeEnvelope(hints: ["a": "b"])
        let bytes = try CanonicalEnvelopeLineEncoder().encode(envelope)
        #expect(bytes.last == 0x0A)
        #expect(!bytes.dropLast().contains(0x0A))
    }
}
