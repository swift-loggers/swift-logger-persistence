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
    case closeWritableSegment
    /// Pre-admission validation boundary.
    case validateEnvelope
    case encodeEnvelope
    /// First mutating-storage boundary.
    case admitEnvelope
    case appendEnvelopeBytes
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

## Byte-stable export -- M3.3.2

`FileLogStore` exposes a single concrete export method. Per-protocol
shape (`ExportableLogStore` with `removeExportedLogs()`) is deferred
because adding a protocol requirement after release would be a public
API break; the protocol lands together with the destructive
`removeExportedLogs()` lifecycle in a later milestone.

```swift
extension FileLogStore {
    public func exportLogs(
        to url: URL
    ) async throws(FileLogStoreExportError)
}
```

Public error surface lives in
`Sources/LoggerFilePersistence/FileLogStoreExportError.swift`:

- `FileLogStoreExportError.operationFailed(operation:url:context:)`
- `FileLogStoreExportError.interiorCorruption(segmentURL:byteOffset:classification:)`
- `FileLogStoreExportError.invalidDestination(reason:)`

The public `FileLogStoreExportCorruptionClass` taxonomy is part of
the file-store export compatibility contract. Adding a new internal
classification requires a public addition before it can be projected.

Serialization semantics:

- The actor executes `exportLogs(to:)` without interleaving
  `append`, `flush`, or rotation. Export discovery and export
  writes execute within the same actor-isolated operation;
  concurrent callers wait for actor-isolated execution.
- `exportLogs(to:)` does not call `flush()` implicitly. Recoverable
  visibility is the durability boundary. Callers that want
  export-after-flush call `flush()` themselves.
- Bytes outside a segment's recoverable prefix are never exported.

Atomicity contract:

- Any pre-existing entry at the destination URL yields
  `.invalidDestination(reason:)`; the destination is not modified.
- Export writes to a unique temporary file in the destination parent
  directory using no-overwrite creation semantics.
- The temporary file's contents are made durable before the commit.
- Final commit is atomic and must not overwrite an existing
  destination.
- Directory-entry durability after commit is best-effort.
- On any failure between create and commit the export attempts
  temporary-file cleanup. The export never creates partial final bytes
  and never overwrites a destination that materializes concurrently.

Bytes contract:

- Export output is the concatenation of accepted bytes from
  discovered segments in accepted ordering (`.never` →
  `log.ndjson`; `.bySize` → rotated segments ascending by
  numeric sequence).
- Accepted bytes are preserved byte-for-byte from each segment's
  recoverable prefix in accepted ordering. No decoding,
  re-encoding, canonicalization, or extra LF/footer occurs.
- Empty recoverable prefix → 0-byte file at the destination,
  success.
- Interior corruption mid-scan aborts before commit; the export
  creates no final URL and attempts temp cleanup.
- Duplicate `sequence` values are preserved verbatim; logical
  duplicate detection is a separate future API.

## Future shape (deferred -- not in M3.3.2)

Deferred non-normative sketches.

### Export and remove protocol

```text
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
```

`exportLogs(to:)` will conform `FileLogStore` to this protocol when
`removeExportedLogs()` lands; the public method signature stays
compatible.

### Rotation and retention

This sketch shows the joint future shape across rotation (LGP-6, shipped
in M3.3.1) and retention (LGP-7, deferred to M3.3.2). Members marked with
`// M3.3.2` are not part of the current API surface; they document the
slot reserved for the next milestone.

Configuration validation is factory-owned; composition is
non-throwing.

```text
extension FileLogStore.Configuration {
    public init(directory: URL, rotation: RotationPolicy)
    public init(
        directory: URL,
        rotation: RotationPolicy,
        retention: RetentionPolicy
    )                                                       // M3.3.2

    public var rotation: RotationPolicy
    public var retention: RetentionPolicy                   // M3.3.2
}

public struct RotationPolicy: Sendable, Equatable {
    public static let never: Self
    public static func bySize(
        maxSegmentBytes: Int
    ) throws(FileLogStoreConfigurationError) -> Self
}

public struct RetentionPolicy: Sendable, Equatable {        // M3.3.2
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
    case invalidRetentionPolicy                             // M3.3.2
}
```

`RotationPolicy.bySize(maxSegmentBytes:)` rejects any cap below
`FileLogStore.maxEncodedLineBytes`, because a single canonical line that
fits the encoded-line cap must also fit a fresh empty segment; otherwise
admission could produce a line that no segment could hold.

Segment topology under `bySize` is a policy contract, not part of the
portable wire format: rotated segments use filenames of the form
`log.<N>.ndjson` with `<N>` zero-padded to at least six digits;
sequences that exceed the padding boundary grow naturally to wider
names. Reopen discovery is width-independent, reopens from the highest
decimal sequence present, and preserves append cardinality across
reopen and rotation boundaries.

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
