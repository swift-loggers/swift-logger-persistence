# API Design Draft

This document is design input for M3.3. Public API is locked by accepted
API/spec review, then verified by implementation and conformance tests.

File-format and recoverability contract is defined in
`FileFormatSpec.md`.

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
    /// Performs store flush; recoverability contract lives in FileFormatSpec.md.
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

- Produces redacted package-owned payloads. Privacy redaction applies
  to message privacy segments and attribute values; record `domain`,
  attribute keys, and object keys are schema/key material and are
  persisted verbatim. Callers must keep those names non-sensitive and
  PII-free.
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

M3.3.0 baseline capabilities:

- append/flush-only persistence API
- no replay APIs
- no retention enforcement

M3.3.2 adds byte-stable export, destructive removal, and count-,
byte-, and age-based retention below.

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

Storage permissions:

- A directory the file-store creates itself is owner-only
  (`0o700`); a pre-existing directory at the configured path
  is left as-is and the file-store never tightens its
  permissions.
- A segment file the file-store creates (under any rotation
  policy) is owner-only (`0o600`); a pre-existing segment file
  is reused without permission change.
- Compaction never widens segment permissions past the
  writer-private (`0o600` / `0o700`) default; group and world
  bits are dropped from the replacement segment even if the
  pre-compaction boundary segment carried them.
- The file-store does not mutate any process-wide permission
  state (no `umask` mutation) and the writer-private contract
  does not depend on the process umask.

## Byte-stable export -- M3.3.2

`FileLogStore` exposes a concrete typed export method. The portable
`ExportableLogStore` protocol pairs byte-stable export with the
destructive remove lifecycle so the protocol does not need a later
requirement addition.

```swift
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}

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

For `operationFailed`, `url` is the operation-relevant URL; it is not
always the final destination URL. For `interiorCorruption`,
`segmentURL` identifies the scanned source segment, while `byteOffset`
is the byte offset in the accepted-ordering export stream defined by
`FileFormatSpec.md`, not a segment-local offset or a raw file
EOF-relative offset. Destination validation happens before export
boundary capture, so `invalidDestination` does not authorize removal.

The public `FileLogStoreExportCorruptionClass` taxonomy is part of
the file-store export source/API compatibility contract. Adding a new
internal classification requires a public addition before it can be
surfaced through the public export API. Unknown internal corruption
classes must not be mapped onto an existing public class only to avoid
a public API addition.

Serialization semantics:

- `exportLogs(to:)` holds the nonreentrant operation boundary for
  export discovery and export writes. Concurrent `append`, `flush`,
  `exportLogs(to:)`, and `removeExportedLogs()` callers wait until
  the export releases the nonreentrant operation boundary.
- `exportLogs(to:)` does not call `flush()` implicitly. Recoverable
  visibility defines the persistence contract boundary. Callers that
  want export-after-flush call `flush()` themselves.
- Bytes outside a segment's recoverable prefix are never exported.

Atomicity contract:

- Any pre-existing entry at the destination URL yields
  `.invalidDestination(reason:)`; the final destination entry is not
  modified.
- Export writes to a unique temporary file inside a private
  temporary directory in the destination parent using no-overwrite
  creation semantics.
- Export destination file is created owner-only (`0o600`) and
  the atomic rename preserves that mode on the final entry.
  The API does not depend on the process umask and does not
  mutate any process-wide permission state.
- A symlink at the destination parent path is rejected as
  `.invalidDestination(.parentDirectoryInvalid)` and the
  symlink target is not written to.
- The temporary file's contents are flushed before the atomic commit.
- Final commit is atomic and must not overwrite an existing
  destination.
- Destination-parent directory-entry persistence after commit is
  best-effort and not verified by the API.
- On any failure between create and commit the export attempts
  temporary-file cleanup. The export never creates partial final bytes
  and never overwrites a destination that materializes concurrently.

Bytes contract:

- Export output is the concatenation of accepted bytes from
  discovered segments in accepted ordering (`.never` →
  `log.ndjson`; `.bySize` → rotated segments ascending by
  numeric sequence).
- Accepted bytes are preserved byte-for-byte without normalization from
  each segment's recoverable prefix in accepted ordering, including
  duplicate sequence values. No decoding, re-encoding,
  canonicalization, or extra LF/footer occurs.
- Empty recoverable prefix → 0-byte file at the destination,
  success.
- Interior corruption mid-scan aborts before commit; the export
  creates no final URL and attempts temp cleanup.
- Duplicate `sequence` values are preserved verbatim; logical
  duplicate detection is a separate future API outside the export
  contract.

## Destructive removal -- M3.3.2

`FileLogStore` implements the destructive remove lifecycle behind
the `ExportableLogStore` conformance. Removal is authorized only by
the in-memory boundary captured by a prior successful byte-stable
export.

```swift
extension FileLogStore: ExportableLogStore {
    public func removeExportedLogs() async throws(FileLogStoreRemoveError)
}
```

Public error surface lives in
`Sources/LoggerFilePersistence/FileLogStoreRemoveError.swift`:

- `FileLogStoreRemoveError.operationFailed(operation:url:context:)`
- `FileLogStoreRemoveError.noExportedRemovalBoundary`
- `FileLogStoreRemoveError.removalBoundaryStale(url:context:)`
- `FileLogStoreRemoveError.implementationInvariantViolation(violation:)`

Removal-boundary contract:

- `exportLogs(to:)` captures the removal boundary only after the
  final export destination commit succeeds.
- A failed export does not create or advance a removal boundary.
- The boundary is implicit and in-memory. Restart clears it; a later
  remove fails with `.noExportedRemovalBoundary`.
- Bytes before `exportedPrefixEnd` are eligible for removal.
- Accepted bytes at or after `exportedPrefixEnd` are outside the
  removal boundary and must be preserved byte-for-byte.
- Segments created after export are outside the boundary and must not
  be removed.

Serialization semantics:

- `removeExportedLogs()` holds the nonreentrant operation boundary
  while processing the removal boundary. Concurrent `append`,
  `flush`, `exportLogs(to:)`, and `removeExportedLogs()` callers
  wait until removal releases the nonreentrant operation boundary.
- Once physical removal begins, the destructive mutation path does
  not suspend.

Removal mechanics:

- Fully exported non-active rotated segments are unlinked.
- Fully exported active segments preserve no accepted bytes preceding
  the removal boundary, and subsequent appends continue from the reset
  active segment.
- Segments with post-boundary bytes preserve the post-boundary suffix
  byte-for-byte through a unique sibling temporary file whose contents
  are flushed before the atomic commit that replaces the original
  segment.
- Removal never treats `exportedPrefixEnd` as the new segment length;
  that would keep exported bytes and delete post-boundary bytes.
- Active-segment compaction coordinates with writer ownership so
  appends continue after the preserved post-boundary suffix without
  replay or re-encoding.

Failure and retry contract:

- Before mutation, every remaining boundary entry must still refer to
  the same file identity, current file size must be at least
  `exportedPrefixEnd`, and ambiguous rotated topology must fail
  closed.
- Stale boundary detection yields `.removalBoundaryStale` before
  destructive mutation of that entry.
- Removal is retryable per segment within a captured boundary after
  partial destructive progress, not all-or-nothing across all entries.
  Completed destructive steps are not retried.
- On failure, the remaining in-memory boundary is retained for retry.
- On full success, the boundary is cleared. A second remove without a
  new successful export fails with `.noExportedRemovalBoundary`.
- Directory-entry persistence after unlink or replace is best-effort
  and must not be overclaimed.

## Rotation and retention

Rotation (LGP-6, shipped in M3.3.1) and retention (LGP-7, shipped in
M3.3.2) compose through ``FileLogStore.Configuration``. Configuration
validation is factory-owned; composition is non-throwing.

```text
extension FileLogStore.Configuration {
    public init(directory: URL)
    public init(directory: URL, rotation: RotationPolicy)
    public init(
        directory: URL,
        rotation: RotationPolicy,
        retention: RetentionPolicy
    )

    public var directory: URL
    public var rotation: RotationPolicy
    public var retention: RetentionPolicy
}

public struct RotationPolicy: Sendable, Equatable {
    public static let never: Self
    public static func bySize(
        maxSegmentBytes: Int
    ) throws(FileLogStoreConfigurationError) -> Self
}

public struct RetentionPolicy: Sendable, Equatable {
    public static let unlimited: Self
    public static func maxSegments(
        _ count: Int
    ) throws(FileLogStoreConfigurationError) -> Self
    public static func maxTotalBytes(
        _ bytes: Int
    ) throws(FileLogStoreConfigurationError) -> Self
    public static func maxAge(
        seconds: Int64
    ) throws(FileLogStoreConfigurationError) -> Self
}

public enum FileLogStoreConfigurationError: Error, Sendable, Equatable {
    case invalidRotationPolicy
    case invalidRetentionPolicy
}
```

`Configuration(directory:)` and `Configuration(directory:rotation:)` set
`retention = .unlimited`.

`RotationPolicy.bySize(maxSegmentBytes:)` rejects any cap below
`FileLogStore.maxEncodedLineBytes`, because a single canonical line that
fits the encoded-line cap must also fit a fresh empty segment; otherwise
admission could produce a line that no segment could hold.

`RetentionPolicy.maxSegments(_:)` rejects values below `1`. A retention
cap of zero would force retention to delete the active writer segment
to satisfy the bound, which retention is forbidden from doing.

`RetentionPolicy.maxTotalBytes(_:)` rejects values below
`FileLogStore.maxEncodedLineBytes`. A canonical line that fits the
encoded-line cap must be admittable into a fresh empty segment; a
smaller cap would force retention to consider deleting a segment
containing the line that just admitted it.

`RetentionPolicy.maxAge(seconds:)` rejects values below `1`. Age
retention deletes a rotated segment once `now - mtime >= seconds`,
where `mtime` is the filesystem modification time read by
`fstatat(AT_SYMLINK_NOFOLLOW)`. The policy does not parse envelope
payloads or accepted-line timestamps and does not depend on
calendar/DST math. The active writer segment is never deleted, even
when its mtime would qualify. Candidate ordering is mtime-ascending
with the segment-enumerator's sequence-ascending order as a
deterministic tie-break.

Retention enforcement runs after a successful `append` admission inline
while the append still holds the nonreentrant operation boundary.
Concurrent `append`, `flush`, `exportLogs(to:)`, and
`removeExportedLogs()` callers wait until the append plus retention
enforcement releases that nonreentrant operation boundary. Rejected
appends never trigger retention enforcement. A failed retention pass
does not roll back the admitted append.

Under `RotationPolicy.bySize(maxSegmentBytes:)`, retention enumerates
regular rotated segments by numeric sequence and deletes whole rotated
segments only — never the active writer segment, never inside-segment
prefix bytes, and never an accepted line. Under `RotationPolicy.never`
every retention policy is a no-op because there is only one unrotated
segment to consider and prefix retention requires a separate boundary
model. `RetentionPolicy.unlimited` is a no-op under any rotation.

If retention deletion fails, the triggering append remains admitted
and the caller receives `.operationFailed(.enforceRetention, url:
..., context: ...)`. Later append/flush/export/remove operations
operate on the recoverable on-disk topology left by the failed pass.
Directory-entry persistence after unlink is best-effort and must not
be overclaimed.

Retention does not create, consume, or modify the in-memory removal
boundary. A retention pass that deletes a segment named in an older
captured export boundary makes that boundary stale; the next
`removeExportedLogs()` then fails closed with
`.removalBoundaryStale`.

Segment topology under `bySize` is a policy contract, not part of the
portable wire format: rotated segments use filenames of the form
`log.<N>.ndjson` with `<N>` zero-padded to at least six digits;
sequences that exceed the padding boundary grow naturally to wider
names. Reopen discovery is width-independent, reopens from the highest
decimal sequence present, and preserves append cardinality across
reopen and rotation boundaries.

Calendar-day rotation is omitted until timezone ownership, DST handling,
and boundary monotonicity are defined.

## Future shape (deferred)

Deferred non-normative sketches.

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
