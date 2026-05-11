import Foundation
@_spi(WireFormat) import LoggerPersistence

/// Raised when an envelope timestamp cannot be rendered by the
/// canonical timestamp profile.
enum CanonicalEnvelopeEncodingError: Error, Equatable {
    case nonRenderableDate
}

/// Encodes a `PersistentLogEnvelope` into one canonical
/// LF-terminated NDJSON envelope line.
///
/// Wire format defined by the file-format specification ("Wire
/// Format" and "Deterministic Encoding"): one LF-terminated JSON
/// object per envelope, canonical key order, canonical RFC 3339
/// UTC millisecond timestamp, base64-encoded payload.
struct CanonicalEnvelopeLineEncoder {
    /// Returns the canonical LF-terminated NDJSON bytes for one
    /// envelope.
    ///
    /// - Throws: ``CanonicalEnvelopeEncodingError/nonRenderableDate``
    ///   if `envelope.createdAt` falls outside the canonical RFC
    ///   3339 UTC millisecond profile.
    func encode(
        _ envelope: PersistentLogEnvelope
    ) throws(CanonicalEnvelopeEncodingError) -> Data {
        var output = ""
        output.reserveCapacity(512)
        // Top-level object keys are emitted in canonical UTF-8 byte order.
        output.append("{\"contentType\":")
        writeString(envelope.contentType, into: &output)
        output.append(",\"createdAt\":")
        try writeRFC3339Date(envelope.createdAt, into: &output)
        output.append(",\"hints\":")
        writeStringMap(envelope.hints, into: &output)
        output.append(",\"id\":")
        writeUUID(envelope.id, into: &output)
        output.append(",\"payload\":")
        writeBase64(envelope.payload, into: &output)
        output.append(",\"sequence\":")
        output.append(String(envelope.sequence))
        output.append("}\n")
        return Data(output.utf8)
    }

    private func writeRFC3339Date(
        _ date: Date,
        into output: inout String
    ) throws(CanonicalEnvelopeEncodingError) {
        guard let canonical = CanonicalTimestamp.canonicalString(from: date) else {
            throw .nonRenderableDate
        }
        output.append("\"")
        output.append(canonical)
        output.append("\"")
    }

    private func writeStringMap(
        _ map: [String: String],
        into output: inout String
    ) {
        output.append("{")
        // Sort before escaping; the spec compares original UTF-8 key bytes.
        let sorted = map.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        var first = true
        for (key, value) in sorted {
            if !first { output.append(",") }
            first = false
            writeString(key, into: &output)
            output.append(":")
            writeString(value, into: &output)
        }
        output.append("}")
    }

    private func writeUUID(_ uuid: UUID, into output: inout String) {
        output.append("\"")
        output.append(uuid.uuidString.lowercased())
        output.append("\"")
    }

    private func writeBase64(_ data: Data, into output: inout String) {
        // Standard base64 alphabet contains the solidus, which the
        // canonical JSON escape table emits as `\/`; route the string
        // through `writeString` instead of appending verbatim.
        writeString(data.base64EncodedString(), into: &output)
    }

    private static let lowercaseHexDigit: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f"
    ]

    private func writeString(_ string: String, into output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            if let escape = stringEscape(for: scalar) {
                output.append(escape)
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                // Other ASCII control characters: emit `\u00XX` via
                // a fixed lowercase-hex table to keep the canonical
                // byte path independent of Foundation formatters.
                output.append("\\u00")
                output.append(Self.lowercaseHexDigit[Int(scalar.value >> 4)])
                output.append(Self.lowercaseHexDigit[Int(scalar.value & 0xF)])
            } else {
                // Non-ASCII scalars are emitted as UTF-8, not \u escapes.
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }

    /// Returns the canonical JSON escape sequence for `scalar`, or
    /// `nil` if the scalar is emitted verbatim. Solidus is escaped
    /// as `\/` per the package canonical bytes profile.
    private func stringEscape(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "\"": "\\\""
        case "\\": "\\\\"
        case "/": "\\/"
        case "\u{08}": "\\b"
        case "\u{09}": "\\t"
        case "\u{0A}": "\\n"
        case "\u{0C}": "\\f"
        case "\u{0D}": "\\r"
        default: nil
        }
    }
}
