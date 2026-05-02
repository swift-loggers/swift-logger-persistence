# API Design Draft

This document is design input for M3.3. Public API is locked by accepted
API/spec review, then verified by implementation and conformance tests.

File-format and durability contract is defined in `FileFormatSpec.md`.

`APIDesign.md` owns API shape and API-observable guarantees only.
`FileFormatSpec.md` owns persistence terminology and wire-format
contract. `APICompatibility.md` owns public diagnostic evolution.

> **Snippet convention.** Code blocks in this document use text-tagged
> code fences so the repo's local snippet runner skips them; some are
> intentionally not standalone Swift. The implementation PR will add the
> validated Swift API under `Sources/LoggerPersistence/` and
> `Sources/LoggerFilePersistence/`.

## Envelope and store -- M3.3.0

```text
public struct PersistentLogEnvelope: Sendable, Equatable {
    public let id: UUID
    /// `0` is reserved and invalid. Sequence comparison is numeric, not
    /// lexical.
    public let sequence: UInt64
    /// Producer timestamp; not admission timestamp.
    public let createdAt: Date
    public let contentType: String
    /// Hint iteration order is not an API guarantee.
    public let hints: [String: String]
    public let payload: Data
}

public protocol PersistentLogStore: Sendable {
    /// Successful append reaches admission. Producer sequence remains
    /// producer-owned metadata.
    func append(_ envelope: PersistentLogEnvelope) async throws
    /// Performs store flush; durability contract lives in FileFormatSpec.md.
    func flush() async throws
}
```

Terminology follows `FileFormatSpec.md`.

Envelope observable guarantees:

- `id` identifies one envelope. It is not an ordering key.
- Byte preservation terms are defined in `FileFormatSpec.md`.
- Payload opacity terms are defined in `FileFormatSpec.md`.

## Record-aware encoder -- M3.3.0

```text
/// Assigns producer sequence synchronously and monotonically per encoder
/// instance before async persistence boundaries.
/// Producer sequence assignment occurs before persistence admission.
public final class LogRecordPersistentEncoder: @unchecked Sendable {
    public static let contentType: String
    public init()
    public func encode(_ record: LogRecord) throws -> PersistentLogEnvelope
}
```

Encoder guarantees:

- Produces redacted package-owned payloads.
- Sequence assignment is per-encoder-instance monotonic.
- Does not perform store admission.

## File-backed store -- M3.3.0

```text
public actor FileLogStore: PersistentLogStore {
    public init(configuration: Configuration)

    public func append(_ envelope: PersistentLogEnvelope) async throws(FileLogStoreError)
    public func flush() async throws(FileLogStoreError)
}

extension FileLogStore {
    public struct Configuration: Sendable {
        public var directory: URL
        public init(directory: URL)
    }
}

public enum FileLogStoreError: Error, Sendable, Equatable {
    /// Operation-local classification for non-compatibility-classified
    /// filesystem failures.
    case operationFailed(
        operation: FileLogStoreOperation,
        url: URL,
        context: FileSystemErrorContext
    )
    case invalidEnvelope(reason: FileLogStoreEnvelopeValidationError)
    case implementationInvariantViolation(
        violation: PersistenceInvariantError
    )
}

public enum PersistenceInvariantError: String, Sendable, Equatable {
    /// Append completed without producing the expected recoverable line.
    case appendProducedNoRecoverableLine
    /// Append produced more than one recoverable line.
    case appendProducedMultipleRecoverableLines
    /// Append mutated the prior recoverable prefix.
    case appendRewroteRecoverablePrefix
    /// Encoded line is missing its trailing LF delimiter.
    case encodedEnvelopeMissingTrailingLF
    /// Encoded line contains an LF before its final delimiter.
    case encodedEnvelopeContainsInteriorLF
    /// Corrupt envelope was accepted as valid.
    case corruptEnvelopeAccepted
    /// Corruption class did not match corpus expectations.
    case corruptionClassificationMismatch
}

public enum FileLogStoreEnvelopeValidationError: Sendable, Equatable {
    case invalidCanonicalEnvelopeIdentifier
    case invalidSequence
    case invalidCreatedAt
    case invalidContentType
    case tooManyHints(limit: Int, actual: Int)
    case invalidHintKey(key: String)
    case hintValueTooLong(key: String, limitBytes: Int, actualBytes: Int)
    /// Scalar-based control-character validation; no normalization before
    /// validation.
    case invalidHintValueControlCharacter(key: String)
    case rawPayloadTooLarge(limitBytes: Int, actualBytes: Int)
    case encodedEnvelopeLineTooLarge(limitBytes: Int, actualBytes: Int)
}

public enum FileLogStoreOperation: String, Sendable, Equatable {
    case createDirectory
    case openWritableSegment
    /// Pre-admission validation boundary.
    case validateEnvelope
    case encodeEnvelope
    /// First mutating-storage boundary.
    case admitEnvelope
    /// Writes one validated line per append operation.
    case appendEnvelopeBytes
    /// Local synchronization operation.
    case flushBoundary
}

public struct FileSystemErrorContext: Sendable, Equatable {
    public let domain: String
    public let code: Int?
    /// Non-stable diagnostic text; must not drive replay/export or
    /// compatibility decisions.
    public let description: String
    public init(domain: String, code: Int?, description: String)
    public init(from error: any Error)
}
```

M3.3.0 target capabilities documented by this spec-only PR:

- append/flush-only persistence API
- no replay/export APIs
- deferred retention

Segment topology is outside the portable compatibility contract.

Error guarantees:

- File-system and encoding failures are reported as
  `FileLogStoreError.operationFailed`.
- Envelope validation failures are reported as
  `FileLogStoreError.invalidEnvelope`.
- Implementation invariant failures are reported as
  `FileLogStoreError.implementationInvariantViolation`.
- Invariant failures report implementation defects, not caller
  validation failures.

## Future shape (deferred -- not in M3.3.0)

Deferred non-normative sketches.

### Export and remove

```text
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
```

### Rotation and retention

```text
extension FileLogStore.Configuration {
    public init(
        directory: URL,
        rotation: RotationPolicy,
        retention: RetentionPolicy
    ) throws(FileLogStoreConfigurationError)

    public var rotation: RotationPolicy
    public var retention: RetentionPolicy
}

public struct RotationPolicy: Sendable {
    public static let never: Self
    public static func bySize(
        maxSegmentBytes: Int
    ) throws(FileLogStoreConfigurationError) -> Self
}

public struct RetentionPolicy: Sendable {
    public static let unlimited: Self
    public static func maxSegments(
        _ count: Int
    ) throws(FileLogStoreConfigurationError) -> Self
    /// Monotonic elapsed-time policy; not calendar/DST age.
    public static func maxAge(
        seconds: Int64
    ) throws(FileLogStoreConfigurationError) -> Self
    public static func maxTotalBytes(
        _ bytes: Int
    ) throws(FileLogStoreConfigurationError) -> Self
}

public enum FileLogStoreConfigurationError: Error, Sendable, Equatable {
    case invalidRotationPolicy
    case invalidRetentionPolicy
}
```

Calendar-day rotation is omitted until timezone ownership, DST handling,
and boundary monotonicity are defined.

### File protection -- when actually applied at write

```text
extension FileLogStore.Configuration {
    public var fileProtection: FileProtectionPolicy
}

public enum FileProtectionPolicy: Sendable {
    case `default`
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
    case none
}
```

Protection policy is platform-defined and outside the persistence
compatibility contract.
