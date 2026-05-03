import Foundation
import LoggerPersistence
import Testing

@testable import LoggerFilePersistence

/// Canonical envelope-line encoder coverage for the wire format
/// defined by `Docs/FileFormatSpec.md`.
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

    @Test("Encoder emits canonical top-level keys in UTF-8 byte order with LF terminator")
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

    @Test("Encoder escapes solidus inside string values as `\\/`")
    func solidusEscapingInsideStringValues() throws {
        let envelope = try Self.makeEnvelope(contentType: "application/json")
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""contentType":"application\/json""##))
    }

    @Test("Encoder escapes the canonical solidus, backslash, and quote in hint values")
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

    @Test("Encoder emits non-ASCII scalars as UTF-8 bytes, not `\\u` escapes")
    func nonASCIIEmittedAsUTF8Bytes() throws {
        let envelope = try Self.makeEnvelope(hints: ["key": "café"])
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""key":"café""##))
        // Non-ASCII scalars participate in the canonical line as raw UTF-8 bytes.
        // The escape form `\u00e9` (six literal ASCII chars) must not appear.
        #expect(!line.contains(##"\u00e9"##))
    }

    @Test("Encoder emits id in canonical lower-case `8-4-4-4-12` form")
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

    @Test("Encoder emits empty hints object as `{}`")
    func emptyHintsObjectShape() throws {
        let envelope = try Self.makeEnvelope(hints: [:])
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""hints":{}"##))
    }

    @Test("Encoder sorts hint keys by UTF-8 byte order, not insertion order")
    func hintKeysSortedByUTF8ByteOrder() throws {
        let envelope = try Self.makeEnvelope(
            hints: ["zeta": "z", "alpha": "a", "middle": "m"]
        )
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""hints":{"alpha":"a","middle":"m","zeta":"z"}"##))
    }

    @Test("Encoder emits payload as standard base64 with padding")
    func payloadEmittedAsStandardBase64() throws {
        // `Hello` in UTF-8 → standard base64 `SGVsbG8=`.
        let envelope = try Self.makeEnvelope(payload: Data("Hello".utf8))
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""payload":"SGVsbG8=""##))
    }

    @Test("Encoder escapes the standard base64 alphabet's solidus inside the payload field")
    func payloadBase64SolidusIsEscaped() throws {
        // Three `0xFF` bytes encode to base64 `////`; each solidus
        // escapes to `\/` per the canonical JSON escape table.
        let envelope = try Self.makeEnvelope(payload: Data([0xFF, 0xFF, 0xFF]))
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""payload":"\/\/\/\/""##))
    }

    @Test("Encoder emits sequence as a JSON number, not a string")
    func sequenceEmittedAsJSONNumber() throws {
        let envelope = try Self.makeEnvelope(sequence: 42)
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""sequence":42"##))
    }

    @Test("Encoder emits createdAt with fixed millisecond fractional precision")
    func createdAtRendersWithFixedMillisecondPrecision() throws {
        let envelope = try Self.makeEnvelope(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        let line = try Self.encodedString(envelope)
        #expect(line.contains(##""createdAt":"2023-11-14T22:13:20.123Z""##))
    }

    @Test("Encoder produces only one LF in the encoded line, at the very end")
    func encodedLineHasSingleTrailingLF() throws {
        let envelope = try Self.makeEnvelope(hints: ["a": "b"])
        let bytes = try CanonicalEnvelopeLineEncoder().encode(envelope)
        let lfCount = bytes.filter { $0 == 0x0A }.count
        #expect(lfCount == 1)
        #expect(bytes.last == 0x0A)
    }
}
