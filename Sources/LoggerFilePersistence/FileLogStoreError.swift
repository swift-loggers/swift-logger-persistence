import Foundation

/// A typed error thrown by ``FileLogStore``.
///
/// Failure surface is defined by `Docs/FileFormatSpec.md`.
public enum FileLogStoreError: Error, Sendable, Equatable {
    /// A file-system or encoding step failed mid-operation.
    ///
    /// The associated values name the pipeline step
    /// (``FileLogStoreOperation``) that surfaced the failure, the
    /// `URL` the step was acting on, and a value-typed
    /// ``FileSystemErrorContext`` snapshot of the underlying error.
    case operationFailed(
        operation: FileLogStoreOperation,
        url: URL,
        context: FileSystemErrorContext
    )

    /// The envelope failed pre-admission validation defined by
    /// `Docs/FileFormatSpec.md` ("Validation").
    case invalidEnvelope(reason: FileLogStoreEnvelopeValidationError)

    /// An implementation invariant was violated.
    ///
    /// Signals an implementation defect, not a caller-actionable
    /// validation failure.
    case implementationInvariantViolation(violation: PersistenceInvariantError)
}

/// The step in the file-store pipeline that ``FileLogStore`` was
/// performing when an error surfaced.
///
/// Listed in pipeline order. Operations are append-only within one
/// package major version per `Docs/APICompatibility.md`.
public enum FileLogStoreOperation: String, Sendable, Equatable {
    /// Creating the segment directory.
    case createDirectory
    /// Opening or creating the writable segment file and seeking
    /// to its end.
    case openWritableSegment
    /// Closing a segment file at a rotation boundary.
    case closeWritableSegment
    /// Pre-admission validation boundary.
    case validateEnvelope
    /// Canonical envelope-line encoding step.
    case encodeEnvelope
    /// First mutating-storage boundary.
    case admitEnvelope
    case appendEnvelopeBytes
    case flushBoundary
}

/// Pre-admission envelope validation failures defined by
/// `Docs/FileFormatSpec.md` ("Validation").
///
/// Cases are listed in the spec's "Validation Precedence" order.
public enum FileLogStoreEnvelopeValidationError: Sendable, Equatable {
    /// `id` is not in the canonical hyphenated RFC 4122 form with
    /// lower-case hexadecimal digits (`8-4-4-4-12`).
    case invalidCanonicalEnvelopeIdentifier
    /// `sequence` is `0` (reserved and invalid; valid values are
    /// `1...UInt64.max`).
    case invalidSequence
    /// `createdAt` is outside the canonical RFC 3339 UTC millisecond
    /// profile.
    case invalidCreatedAt
    /// `contentType` is not 1...128 UTF-8 bytes or contains a byte
    /// outside the visible-ASCII range `0x21...0x7E`.
    case invalidContentType
    /// `hints` contained more than `16` entries.
    case tooManyHints(limit: Int, actual: Int)
    /// A hint key was empty, exceeded the byte cap, or contained a
    /// byte outside the allowed hint-key character set (ASCII
    /// letters, digits, `.`, `_`, `-`). Reported for the
    /// lexicographically first failing key under UTF-8 byte order.
    case invalidHintKey(key: String)
    /// A hint value exceeded the byte cap. Reported for the
    /// lexicographically first failing key under UTF-8 byte order.
    case hintValueTooLong(key: String, limitBytes: Int, actualBytes: Int)
    /// A hint value contained an ASCII control character
    /// (`U+0000...U+001F` or `U+007F`). Scalar-based detection.
    /// Reported for the lexicographically first failing key under
    /// UTF-8 byte order.
    case invalidHintValueControlCharacter(key: String)
    /// Raw `payload` exceeded the portable 1 MiB byte cap.
    case rawPayloadTooLarge(limitBytes: Int, actualBytes: Int)
    /// The encoded envelope line, including base64 payload, JSON
    /// punctuation, and trailing LF, exceeded the line byte cap.
    case encodedEnvelopeLineTooLarge(limitBytes: Int, actualBytes: Int)
}

/// Implementation-defect signals raised by ``FileLogStore``.
///
/// Each case corresponds to a broken postcondition documented in
/// `Docs/FileFormatSpec.md` ("Implementation Invariant Diagnostics").
/// These cases name implementation defects, not caller-actionable
/// validation failures.
public enum PersistenceInvariantError: String, Sendable, Equatable {
    /// `append(_:)` completed without producing the expected
    /// envelope line in the recoverable prefix.
    case appendProducedNoRecoverableLine
    /// One `append(_:)` operation made more than one complete line
    /// recoverable.
    case appendProducedMultipleRecoverableLines
    /// Bytes in the prior recoverable prefix changed during a later
    /// `append(_:)` operation.
    case appendRewroteRecoverablePrefix
    /// The encoded line is missing its trailing LF delimiter.
    case encodedEnvelopeMissingTrailingLF
    /// The encoded line contains an LF before its final delimiter.
    case encodedEnvelopeContainsInteriorLF
    /// A corrupt envelope was reported as valid.
    case corruptEnvelopeAccepted
    /// The corpus-defined corruption class was not preserved.
    case corruptionClassificationMismatch
}

/// Value-typed snapshot of a file-system error.
///
/// Carries the error's domain, code, and localized description so
/// callers can pattern-match the failure cause.
public struct FileSystemErrorContext: Sendable, Equatable {
    /// The error domain (e.g. `NSCocoaErrorDomain`,
    /// `NSPOSIXErrorDomain`).
    public let domain: String
    /// The error code, when the underlying error provides one.
    public let code: Int?
    /// Non-stable diagnostic text. Must not drive replay/export or
    /// compatibility decisions.
    public let description: String

    public init(domain: String, code: Int?, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }

    /// Creates a context from any `Error` by reading its `NSError`
    /// projection.
    public init(from error: any Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
    }
}
