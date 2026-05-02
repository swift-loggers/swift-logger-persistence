import Foundation

/// An opaque, durably-storable envelope wrapping an encoded log payload.
///
/// `PersistentLogEnvelope` is the unit that ``PersistentLogStore``
/// persists. Stores treat ``payload`` as opaque bytes and do not
/// encode or redact them.
///
/// ## Sequence ordering
///
/// ``sequence`` is producer-assigned, monotonic per producer instance,
/// and assigned synchronously before the envelope reaches the store.
/// Stores preserve caller-provided sequence metadata -- they do
/// not reorder, deduplicate, or assign sequences themselves. `0` is
/// reserved and invalid; valid values are `1...UInt64.max`. Producers
/// fail before sequence wrap would occur.
///
/// ## On-disk encoding
///
/// `PersistentLogEnvelope` is intentionally **not** `Codable`. The
/// on-disk envelope and payload bytes are owned by
/// `Docs/FileFormatSpec.md`, not by Foundation's synthesized Codable
/// output.
public struct PersistentLogEnvelope: Sendable, Equatable {
    /// A unique identifier for this envelope.
    public let id: UUID

    /// A monotonic, producer-assigned sequence number in the range
    /// `1...UInt64.max`. `0` is reserved and invalid.
    public let sequence: UInt64

    /// The producer-assigned timestamp for the envelope payload.
    public let createdAt: Date

    /// A visible-ASCII content type identifying the payload format.
    ///
    /// Encoders document their content type so consumers can identify
    /// payload handling semantics without inspecting payload bytes.
    public let contentType: String

    /// Optional metadata available to consumers without decoding ``payload``.
    ///
    /// Iteration order over ``hints`` is not an API guarantee.
    public let hints: [String: String]

    /// The encoded payload. Stores persist this verbatim and must
    /// not inspect it.
    public let payload: Data

    /// Maximum UTF-8 byte length of ``contentType`` per
    /// `Docs/FileFormatSpec.md`.
    public static let maxContentTypeBytes = 128

    /// Maximum number of entries in ``hints`` per
    /// `Docs/FileFormatSpec.md`.
    public static let maxHintsCount = 16

    /// Maximum UTF-8 byte length of a hint key per
    /// `Docs/FileFormatSpec.md`.
    public static let maxHintKeyBytes = 128

    /// Maximum UTF-8 byte length of a hint value per
    /// `Docs/FileFormatSpec.md`.
    public static let maxHintValueBytes = 512

    /// Maximum raw ``payload`` size in bytes per
    /// `Docs/FileFormatSpec.md` ("Payload and Bounds").
    public static let maxPayloadBytes = 1_048_576

    /// Creates a validated envelope.
    ///
    /// Validates against the envelope-level constraints in
    /// `Docs/FileFormatSpec.md`, in the order documented by the
    /// spec's "Validation Precedence" section.
    ///
    /// - Throws: ``PersistentLogEnvelopeValidationError`` if any
    ///   field violates the spec; no envelope is produced and no
    ///   stored property is set.
    public init(
        id: UUID,
        sequence: UInt64,
        createdAt: Date,
        contentType: String,
        hints: [String: String],
        payload: Data
    ) throws(PersistentLogEnvelopeValidationError) {
        guard sequence != 0 else {
            throw .invalidSequence
        }
        try Self.validateCreatedAt(createdAt)
        try Self.validateContentType(contentType)
        try Self.validateHints(hints)
        guard payload.count <= Self.maxPayloadBytes else {
            throw .rawPayloadTooLarge(
                limitBytes: Self.maxPayloadBytes,
                actualBytes: payload.count
            )
        }
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.contentType = contentType
        self.hints = hints
        self.payload = payload
    }

    private static func validateCreatedAt(
        _ date: Date
    ) throws(PersistentLogEnvelopeValidationError) {
        guard CanonicalTimestamp.components(of: date) != nil else {
            throw .invalidCreatedAt
        }
    }

    private static func validateContentType(
        _ value: String
    ) throws(PersistentLogEnvelopeValidationError) {
        // Bound the UTF-8 prefix before counting so caller-controlled
        // oversized inputs do not allocate proportionally to their full size.
        let bytes = value.utf8.prefix(maxContentTypeBytes + 1)
        guard !bytes.isEmpty, bytes.count <= maxContentTypeBytes else {
            throw .invalidContentType
        }
        for byte in bytes {
            // Visible ASCII excluding whitespace and DEL: 0x21..0x7E.
            guard (0x21 ... 0x7E).contains(byte) else {
                throw .invalidContentType
            }
        }
    }

    private static func validateHints(
        _ hints: [String: String]
    ) throws(PersistentLogEnvelopeValidationError) {
        guard hints.count <= maxHintsCount else {
            throw .tooManyHints(limit: maxHintsCount, actual: hints.count)
        }
        // Validation order follows the spec precedence rules.
        let sortedPairs = hints.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        for (key, _) in sortedPairs {
            try validateHintKey(key)
        }
        for (key, value) in sortedPairs {
            try validateHintValueLength(value, key: key)
        }
        for (key, value) in sortedPairs {
            try validateHintValueControlCharacters(value, key: key)
        }
    }

    private static func validateHintKey(
        _ key: String
    ) throws(PersistentLogEnvelopeValidationError) {
        let bytes = key.utf8.prefix(maxHintKeyBytes + 1)
        guard !bytes.isEmpty, bytes.count <= maxHintKeyBytes else {
            throw .invalidHintKey(key: key)
        }
        for byte in bytes {
            guard isAllowedHintKeyByte(byte) else {
                throw .invalidHintKey(key: key)
            }
        }
    }

    private static func isAllowedHintKeyByte(_ byte: UInt8) -> Bool {
        // ASCII letters, digits, `.`, `_`, `-`.
        if (0x61 ... 0x7A).contains(byte) { return true }
        if (0x41 ... 0x5A).contains(byte) { return true }
        if (0x30 ... 0x39).contains(byte) { return true }
        return byte == 0x2E || byte == 0x5F || byte == 0x2D
    }

    private static func validateHintValueLength(
        _ value: String,
        key: String
    ) throws(PersistentLogEnvelopeValidationError) {
        let count = value.utf8.count
        guard count <= maxHintValueBytes else {
            throw .hintValueTooLong(
                key: key,
                limitBytes: maxHintValueBytes,
                actualBytes: count
            )
        }
    }

    private static func validateHintValueControlCharacters(
        _ value: String,
        key: String
    ) throws(PersistentLogEnvelopeValidationError) {
        // Scalar-based detection per `Docs/FileFormatSpec.md`.
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw .invalidHintValueControlCharacter(key: key)
            }
        }
    }
}

/// Errors thrown by ``PersistentLogEnvelope/init(id:sequence:createdAt:contentType:hints:payload:)``.
///
/// Each case names the spec rule the value violated. Limit values
/// are reported alongside the actual value where helpful so callers
/// can produce diagnostic messages without redoing the byte
/// accounting. The associated `key` on hint cases is the failing
/// hint key as supplied by the caller, before any normalization.
public enum PersistentLogEnvelopeValidationError: Error, Sendable, Equatable {
    /// `sequence` was `0`. `0` is reserved and invalid; valid
    /// values are `1...UInt64.max`.
    case invalidSequence

    /// `createdAt` is outside the canonical RFC 3339 UTC millisecond
    /// profile defined by `CanonicalTimestamp` and required by
    /// `Docs/FileFormatSpec.md` ("Timestamp Field").
    case invalidCreatedAt

    /// `contentType` violated one of the envelope-level rules in
    /// `Docs/FileFormatSpec.md` ("Text Fields"): non-empty,
    /// `<=`128 UTF-8 bytes, visible ASCII without whitespace or
    /// control characters.
    case invalidContentType

    /// `hints` contained more than ``PersistentLogEnvelope/maxHintsCount``
    /// entries.
    case tooManyHints(limit: Int, actual: Int)

    /// A hint key was empty, exceeded
    /// ``PersistentLogEnvelope/maxHintKeyBytes``, or contained a
    /// byte outside the allowed hint-key character set (ASCII
    /// letters, digits, `.`, `_`, `-`). Reported for the
    /// lexicographically first failing key under UTF-8 byte order.
    case invalidHintKey(key: String)

    /// A hint value exceeded ``PersistentLogEnvelope/maxHintValueBytes``.
    /// Reported for the lexicographically first failing key under
    /// UTF-8 byte order.
    case hintValueTooLong(key: String, limitBytes: Int, actualBytes: Int)

    /// A hint value contained an ASCII control character
    /// (`U+0000...U+001F` or `U+007F`). Reported for the
    /// lexicographically first failing key under UTF-8 byte order.
    case invalidHintValueControlCharacter(key: String)

    /// Raw `payload` exceeded ``PersistentLogEnvelope/maxPayloadBytes``.
    case rawPayloadTooLarge(limitBytes: Int, actualBytes: Int)
}
