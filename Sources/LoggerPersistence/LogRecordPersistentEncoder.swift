import Foundation
import Loggers

/// Encodes a `Loggers.LogRecord` into a redacted
/// ``PersistentLogEnvelope``.
///
/// The encoder owns three responsibilities:
///
/// 1. **Redaction.** The encoded payload contains only safe-text
///    projections of the message and attributes -- private segments
///    become `<private>` and sensitive ones become `<redacted>`. Raw
///    values for `.private` / `.sensitive` attributes never reach the
///    payload. `.public` attributes are preserved with their typed
///    `LogValue` shape so consumers can re-encode them for downstream
///    backends without reparsing strings.
/// 2. **Monotonic sequence.** ``PersistentLogEnvelope/sequence`` is
///    per-instance monotonic, assigned before any `async` boundary;
///    `0` is reserved and overflow fails closed with
///    ``LogRecordPersistentEncoderError/sequenceExhausted``.
/// 3. **Canonical payload bytes.** The redacted payload is the
///    canonical JSON profile from `Docs/FileFormatSpec.md`
///    ("Deterministic Encoding"): non-finite `Double` values are
///    rejected, and bytes are stable across supported platforms
///    and package patch releases.
///
/// The encoder is `Sendable`; concurrent ``encode(_:)`` calls share
/// only the sequence-counter increment.
public final class LogRecordPersistentEncoder: @unchecked Sendable {
    /// The content type used for envelopes produced by this encoder.
    ///
    /// Matches the redacted `LogRecord` payload version declared in
    /// `Docs/FileFormatSpec.md` ("Payload Format Versioning").
    public static let contentType = "application/vnd.swift-logger.record-redacted.v1+json"

    private let lock = NSLock()
    private var nextSequence: UInt64 = 1

    /// Creates an encoder.
    public init() {}

    /// Internal test seam for sequence-boundary fixtures.
    internal init(initialSequence: UInt64) {
        nextSequence = initialSequence
    }

    /// Encodes a `Loggers.LogRecord` into a redacted envelope.
    ///
    /// - Parameter record: The materialized record to encode.
    /// - Returns: An envelope with a freshly assigned sequence and a
    ///   canonically-encoded redacted JSON payload.
    /// - Throws: ``LogRecordPersistentEncoderError``:
    ///   - ``LogRecordPersistentEncoderError/sequenceExhausted`` when
    ///     the sequence counter has already reached `UInt64.max`.
    ///   - ``LogRecordPersistentEncoderError/nonFiniteDoubleAttribute``
    ///     when any `LogValue.double` in the record is `NaN`, `+inf`,
    ///     or `-inf`.
    ///   - ``LogRecordPersistentEncoderError/canonicalRendererFailure``
    ///     when the canonical binary64 renderer fails for a finite
    ///     input (implementation defect).
    ///   - ``LogRecordPersistentEncoderError/nonRepresentableDate``
    ///     when `record.timestamp` or any `LogValue.date` attribute
    ///     is outside the canonical RFC 3339 UTC millisecond profile.
    ///   - ``LogRecordPersistentEncoderError/unsupportedLogValueCase``
    ///     when an upstream `Loggers.LogValue` case lacks an explicit
    ///     canonical spelling in this encoder version.
    ///   - ``LogRecordPersistentEncoderError/invalidEnvelope(_:)``
    ///     when the resulting envelope would violate the
    ///     envelope-level constraints in `Docs/FileFormatSpec.md`.
    public func encode(_ record: LogRecord) throws(LogRecordPersistentEncoderError) -> PersistentLogEnvelope {
        let sequence = try claimNextSequenceNumber()
        let redacted = RedactedLogRecord(
            timestamp: record.timestamp,
            level: levelString(record.level),
            domain: record.domain.rawValue,
            message: record.message.redactedDescription,
            attributes: record.attributes.map(RedactedLogAttribute.init(from:))
        )
        let canonical = CanonicalRedactedRecordEncoder()
        let payload = try canonical.encode(redacted)
        let hints = [
            "level": redacted.level,
            "domain": redacted.domain
        ]
        do {
            return try PersistentLogEnvelope(
                id: UUID(),
                sequence: sequence,
                createdAt: record.timestamp,
                contentType: Self.contentType,
                hints: hints,
                payload: payload
            )
        } catch {
            // Preserve the encoder's single typed error surface.
            throw .invalidEnvelope(error)
        }
    }

    private func claimNextSequenceNumber() throws(LogRecordPersistentEncoderError) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextSequence
        // Reserve 0 as the terminal failed-closed state after UInt64 overflow.
        guard value != 0 else { throw .sequenceExhausted }
        let (next, overflow) = value.addingReportingOverflow(1)
        nextSequence = overflow ? 0 : next
        return value
    }

    /// `LoggerLevel.rawValue` is the upstream serialization spelling.
    private func levelString(_ level: LoggerLevel) -> String {
        level.rawValue
    }
}

/// Errors thrown by ``LogRecordPersistentEncoder``.
public enum LogRecordPersistentEncoderError: Error, Sendable, Equatable {
    /// The encoder's sequence counter would wrap past `UInt64.max`.
    /// `0` is reserved and invalid for envelope sequences, so the
    /// encoder fails closed instead of emitting an out-of-band
    /// envelope.
    case sequenceExhausted

    /// A `LogValue.double` in the record was not finite (`NaN`,
    /// `+inf`, or `-inf`). The canonical JSON payload profile
    /// (`Docs/FileFormatSpec.md`, section "Deterministic
    /// Encoding") rejects non-finite floating-point values.
    case nonFiniteDoubleAttribute

    /// The canonical binary64 renderer (`CanonicalBinary64`) failed
    /// to produce a verified rendering for a finite `Double` input.
    /// Reserved for an implementation defect in the renderer.
    case canonicalRendererFailure

    /// A future upstream `Loggers.LogValue` case has no canonical
    /// spelling in this encoder version; the encoder fails closed.
    case unsupportedLogValueCase

    /// The redacted record produced an envelope that violates the
    /// envelope-level constraints in `Docs/FileFormatSpec.md`. The
    /// associated value names the failed rule.
    case invalidEnvelope(PersistentLogEnvelopeValidationError)

    /// A `Date` (`record.timestamp` or a `LogValue.date`
    /// attribute) is outside the canonical RFC 3339 UTC
    /// millisecond profile defined by `CanonicalTimestamp`. The
    /// encoder fails closed rather than accepting non-millisecond-
    /// aligned values.
    case nonRepresentableDate
}

/// Package-internal redacted payload model for the canonical
/// JSON profile.
struct RedactedLogRecord: Sendable, Equatable {
    var timestamp: Date
    var level: String
    var domain: String
    var message: String
    var attributes: [RedactedLogAttribute]
}

/// On-disk shape of a redacted attribute. `.public` attributes
/// preserve their typed `Loggers.LogValue`; `.private` and
/// `.sensitive` values are replaced with the redaction sentinels
/// `<private>` and `<redacted>` (encoded as `LogValue.string`).
struct RedactedLogAttribute: Sendable, Equatable {
    var key: String
    var value: LogValue

    /// Builds the redacted projection from a `Loggers.LogAttribute`.
    /// Privacy cases unknown to this encoder version fall through
    /// to `<redacted>`.
    init(from attribute: LogAttribute) {
        key = attribute.key
        switch attribute.privacy {
        case .public:
            value = attribute.value
        case .private:
            value = .string("<private>")
        case .sensitive:
            value = .string("<redacted>")
        @unknown default:
            value = .string("<redacted>")
        }
    }
}

/// Encodes the redacted payload using the package canonical JSON profile.
struct CanonicalRedactedRecordEncoder {
    func encode(_ record: RedactedLogRecord) throws(LogRecordPersistentEncoderError) -> Data {
        var output = ""
        output.reserveCapacity(256)
        // Top-level object keys are emitted in canonical UTF-8 byte order.
        output.append("{\"attributes\":")
        try writeAttributes(record.attributes, into: &output)
        output.append(",\"domain\":")
        writeString(record.domain, into: &output)
        output.append(",\"level\":")
        writeString(record.level, into: &output)
        output.append(",\"message\":")
        writeString(record.message, into: &output)
        output.append(",\"timestamp\":")
        try writeDate(record.timestamp, into: &output)
        output.append("}")
        return Data(output.utf8)
    }

    private func writeAttributes(
        _ attributes: [RedactedLogAttribute],
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        output.append("[")
        var first = true
        for attribute in attributes {
            if !first { output.append(",") }
            first = false
            output.append("{\"key\":")
            writeString(attribute.key, into: &output)
            output.append(",\"value\":")
            try writeValue(attribute.value, into: &output)
            output.append("}")
        }
        output.append("]")
    }

    private func writeValue(
        _ value: LogValue,
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        switch value {
        case let .string(text): writeString(text, into: &output)
        case let .integer(int): output.append(String(int))
        case let .double(double): try writeDouble(double, into: &output)
        case let .bool(bool): output.append(bool ? "true" : "false")
        case let .date(date): try writeDate(date, into: &output)
        case let .array(values): try writeArray(values, into: &output)
        case let .object(dict): try writeObject(dict, into: &output)
        case .null: output.append("null")
        // Fail closed on future LogValue cases without a canonical spelling.
        @unknown default: throw .unsupportedLogValueCase
        }
    }

    private func writeArray(
        _ values: [LogValue],
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        output.append("[")
        var first = true
        for inner in values {
            if !first { output.append(",") }
            first = false
            try writeValue(inner, into: &output)
        }
        output.append("]")
    }

    private func writeObject(
        _ dict: [String: LogValue],
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        output.append("{")
        // Sort object keys by original UTF-8 byte sequence before escaping.
        let sorted = dict.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        var first = true
        for (key, value) in sorted {
            if !first { output.append(",") }
            first = false
            writeString(key, into: &output)
            output.append(":")
            try writeValue(value, into: &output)
        }
        output.append("}")
    }

    private func writeString(_ string: String, into output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            if let escape = stringEscape(for: scalar) {
                output.append(escape)
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                // Other ASCII control characters: emit `\u00XX`.
                output.append(String(format: "\\u%04x", scalar.value))
            } else {
                // Non-ASCII scalars are emitted as UTF-8, not \u escapes.
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }

    /// Returns the canonical JSON escape sequence for a scalar, or
    /// `nil` if the scalar is emitted verbatim. Solidus is escaped as
    /// `\/` per the package canonical bytes profile.
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

    private func writeDouble(
        _ value: Double,
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        guard value.isFinite else {
            throw .nonFiniteDoubleAttribute
        }
        // After the `isFinite` guard, a nil from `render` indicates
        // a renderer invariant violation, not a non-finite input.
        guard let rendered = CanonicalBinary64.render(value) else {
            throw .canonicalRendererFailure
        }
        output.append(rendered)
    }

    /// Renders `date` as RFC 3339 UTC with millisecond precision
    /// and literal `Z`. Maps `CanonicalTimestamp` validation
    /// failures onto
    /// ``LogRecordPersistentEncoderError/nonRepresentableDate``.
    private func writeDate(
        _ date: Date,
        into output: inout String
    ) throws(LogRecordPersistentEncoderError) {
        guard let components = CanonicalTimestamp.components(of: date) else {
            throw .nonRepresentableDate
        }
        let formatted = String(
            format: "\"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ\"",
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second,
            components.millisecond
        )
        output.append(formatted)
    }
}
