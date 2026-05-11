# LoggerFilePersistence Coverage Map

This file maps `LoggerFilePersistence` contract areas to requirement IDs and
test coverage.

This document is non-normative and does not define behavior.
[`Docs/FileFormatSpec.md`](../../Docs/FileFormatSpec.md) remains the
sole normative file-format contract owner.
[`Docs/Requirements.md`](../../Docs/Requirements.md) owns requirement
IDs.

## Contract Coverage Index

| Contract area | Requirement IDs | Status | Primary test location |
| --- | --- | --- | --- |
| Canonical envelope-line encoding | LGP-20, LGP-21, LGP-23, LGP-26, LGP-27, LGP-29 | Covered | `CanonicalEnvelopeLineEncoderTests.swift` |
| Envelope validation and encoded-line caps | LGP-2, LGP-22, LGP-38 | Covered | `FileLogStoreTests.swift`, `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift` |
| Encoded-line shape invariants | LGP-24, LGP-25, LGP-26 | Covered | `FileLogStoreTests.swift`, `CanonicalEnvelopeLineEncoderTests.swift` |
| Append/write path | LGP-1, LGP-11, LGP-24, LGP-25, LGP-27 | Covered | `FileLogStoreTests.swift` |
| Nonreentrant operation-boundary serialization | LGP-8, LGP-9, LGP-19 | Covered | `OperationBoundaryTests.swift`, `FileLogStoreExportTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift` |
| Async rendezvous test infrastructure | LGP-8, LGP-9, LGP-19 | Covered | `TestRendezvousTests.swift`, `FileLogStoreExportTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift` |
| Export temporary confidentiality and permissions | LGP-8, LGP-24, LGP-25, LGP-32 | Covered | `FileLogStoreExportTests.swift`, `FileLogStorePermissionsTests.swift`, [`ByteStableExportSQECoverage.md`](ByteStableExportSQECoverage.md) |
| Writer-private filesystem permissions | LGP-2, LGP-6, LGP-25, LGP-26, LGP-39 | Covered | `FileLogStorePermissionsTests.swift`, `FileLogStoreRemoveTests.swift` |
| Flush and file-handle lifecycle | LGP-5, LGP-12 | Covered | `FileLogStoreTests.swift`, `FileLogStoreReopenTests.swift` |
| Configuration and rotation-policy validation | LGP-2, LGP-6 | Covered | `FileLogStoreRotationTests.swift` |
| Size-based rotation | LGP-6, LGP-39 | Covered | `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift` |
| Rotation filename topology | LGP-6, LGP-39 | Covered | `FileLogStoreRotationTests.swift`, `SegmentEnumerationTests.swift` |
| Segment enumeration | LGP-6, LGP-39 | Covered | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift`, `DuplicateRotatedSegmentTrackerTests.swift` |
| Descriptor-relative root and mid-scan TOCTOU rejection | LGP-2, LGP-6, LGP-14, LGP-15, LGP-39 | Covered | `SymlinkedConfiguredRootTests.swift`, `SegmentEnumerationTests.swift`, `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift` |
| Non-regular and ambiguous segment topology | LGP-2, LGP-6, LGP-39 | Covered | `SegmentEnumerationTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift`, `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `FileLogStoreWriterSymlinkTests.swift`, `SymlinkedConfiguredRootTests.swift` |
| Public store error and invariant mapping | LGP-2, LGP-24, LGP-25, LGP-38, LGP-39 | Covered | `FileLogStoreTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreWriterSymlinkTests.swift`, `FileLogStorePermissionsTests.swift` |
| Internal read error and corruption-class mapping | LGP-16, LGP-17, LGP-18, LGP-33, LGP-35, LGP-36, LGP-37 | Covered | `SegmentEnumerationLstatFailureTests.swift`, [`RecoveryDiscoverySQECoverage.md`](RecoveryDiscoverySQECoverage.md), `CorpusRecoveryTests.swift` |
| Duplicate JSON member detection | LGP-33, LGP-34, LGP-35 | Covered | `JSONDuplicateMemberScannerTests.swift`, `CorpusRecoveryTests.swift` |
| Recovery discovery | LGP-14, LGP-15, LGP-16, LGP-17, LGP-18, LGP-36, LGP-37 | Covered | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift`, `RecoverablePrefixScannerMemoryTests.swift`, `CorpusRecoveryTests.swift`, [`RecoveryDiscoverySQECoverage.md`](RecoveryDiscoverySQECoverage.md) |
| Accepted-line iteration | LGP-14, LGP-15, LGP-19, LGP-27, LGP-30, LGP-31 | Covered | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `AcceptedLineIteratorPullStreamingTests.swift`, `AcceptedLineIteratorCancellationTests.swift`, `AcceptedLineIteratorRereadTests.swift`, `RecoverablePrefixScannerTests.swift`, [`RecoveryDiscoverySQECoverage.md`](RecoveryDiscoverySQECoverage.md) |
| Corpus-governed corruption classification | LGP-33, LGP-34, LGP-35, LGP-36, LGP-37 | Covered | [`RecoveryDiscoverySQECoverage.md`](RecoveryDiscoverySQECoverage.md), `Fixtures/Corpus/` |
| Retention policy | LGP-2, LGP-7, LGP-8, LGP-9, LGP-11, LGP-25, LGP-27, LGP-32 | Covered | `FileLogStoreRetentionTests.swift`, `RetentionSelectionTests.swift`, [`RetentionPolicySQECoverage.md`](RetentionPolicySQECoverage.md) |
| Destructive removal lifecycle | LGP-2, LGP-8, LGP-9, LGP-24, LGP-25, LGP-27, LGP-39 | Covered | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveFailureTests.swift`, `FileLogStoreRemoveStaleBoundaryTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| Byte-stable export API | LGP-8, LGP-14, LGP-15, LGP-16, LGP-17, LGP-30, LGP-31, LGP-32 | Covered | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStoreExportRotatedTests.swift`, `FileLogStoreExportReplayIdentityTests.swift`, [`ByteStableExportSQECoverage.md`](ByteStableExportSQECoverage.md) |
| Logical export API | Future LGP-32 | Future scope (not covered) | Separate future API. Not part of M3.3.2. |

## Coverage Notes

- **Writer-private filesystem permissions.** Newly-created segment files
  materialize as exact owner-readable/writable `0o600`, and a
  newly-created log directory materializes as exact owner-only `0o700`,
  even when the process umask would mask owner bits. Pre-existing
  segment and directory permissions are neither tightened nor widened.
  Compaction never widens segment permissions past the writer-private
  default.
- **Export temporary containment.** No readable regular export temp file
  is exposed in the destination parent during the write phase; covered
  failure-seam paths observe private temp containment cleanup. The export
  payload temp file is created owner-only (`0o600`), and the on-disk mode
  remains `0o600` regardless of process umask. Atomic rename preserves
  that mode on the final destination with no process-wide `umask`
  mutation. A symlink at the destination parent path is rejected as
  `.parentDirectoryInvalid` and the symlink target is not written to.

## Implementation File Index

This table maps every current source file in `Sources/LoggerFilePersistence` to
its primary SQE coverage. It is an index only; the contract-area table above
remains the review entry point.

| Source file | Covered contract areas | Primary test location |
| --- | --- | --- |
| `AcceptedLineIterator.swift` | Accepted-line iteration, policy routing, accepted ordering, byte stability, pull-based laziness, cancellation observation, no-reread after classification, descriptor-relative mid-scan TOCTOU rejection | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `AcceptedLineIteratorPullStreamingTests.swift`, `AcceptedLineIteratorCancellationTests.swift`, `AcceptedLineIteratorRereadTests.swift`, `AcceptedLineIteratorMidScanTOCTOUTests.swift`, [`RecoveryDiscoverySQECoverage.md`](RecoveryDiscoverySQECoverage.md) |
| `CanonicalEnvelopeLineEncoder.swift` | Canonical envelope-line encoding, delimiter ownership, encoded-line byte shape | `CanonicalEnvelopeLineEncoderTests.swift`, `FileLogStoreTests.swift` |
| `EnvelopeLineClassifier.swift` | Read-side envelope validation, JSON scalar-fragment rejection, and corruption classification | `RecoverablePrefixScannerTests.swift`, `EnvelopeLineClassifierJSONFragmentTests.swift`, `CorpusRecoveryTests.swift` |
| `ExportableLogStore.swift` | Public export/remove protocol surface | `FileLogStoreRemoveTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `FileLogStore.swift` | Append/write path, flush, rotation, reopen, trailing-suffix handling, lifecycle seams, descriptor-relative writer opens, actor-owned pending-close queue, removal-boundary actor state, active-writer reset/reopen coordination after destructive removal steps | `FileLogStoreTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `FileLogStoreWriterSymlinkTests.swift`, `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveFailureTests.swift` |
| `FileLogStoreExport.swift` | Byte-stable export surface, atomic no-overwrite destination commit, private export temporary containment, nonreentrant export serialization, descriptor-relative segment read, removal-boundary capture, replay-identity preservation for unknown future `contentType` values | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStoreExportRotatedTests.swift`, `FileLogStoreExportReplayIdentityTests.swift`, [`ByteStableExportSQECoverage.md`](ByteStableExportSQECoverage.md), [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `FileLogStoreExportError.swift` | Public export error taxonomy, destination-topology projection, public corruption-class mapping | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStoreExportRotatedTests.swift` |
| `FileLogStoreExportDestinationValidation.swift` | Caller-input destination URL validation (non-file URL rejection before any path-based derivation), projecting onto `.operationFailed(.validateDestination)` | `FileLogStoreExportDestinationTests.swift` |
| `FileLogStoreExportSegmentWrite.swift` | Per-segment export byte streaming and removal-boundary entry capture | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift`, [`ByteStableExportSQECoverage.md`](ByteStableExportSQECoverage.md), [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `FileLogStoreExportTestSeams.swift` | TEST-ONLY source file: export test seams projecting seam-thrown errors onto export operation failures. | `FileLogStoreExportTests.swift` |
| `FileLogStoreError.swift` | Public store errors, validation errors, invariant mapping, filesystem error context projection | `FileLogStoreTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift` |
| `FileLogStoreInternalTestSeams.swift` | TEST-ONLY seams for writer, export, removal, and retention lifecycle assertions | `FileLogStoreReopenTests.swift`, `FileLogStoreExportTests.swift`, `FileLogStoreRemoveFailureTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift`, `FileLogStoreRetentionTests.swift` |
| `FileLogStoreRemove.swift` | Destructive removal lifecycle, boundary consumption, pending-close drain on removal entry, per-entry dispatch, retry progress tracking, nonreentrant removal serialization | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveFailureTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `FileLogStoreRemoveCompaction.swift` | Removal-boundary revalidation, ambiguous topology rejection, preserved-suffix compaction, temp-file lifecycle, atomic segment replacement | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveStaleBoundaryTests.swift`, `FileLogStoreRemoveFailureTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `FileLogStoreRemoveError.swift` | Public remove error taxonomy, operation mapping, stale-boundary projection | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveStaleBoundaryTests.swift`, `FileLogStoreRemoveFailureTests.swift` |
| `FileLogStoreSegmentIdentity.swift` | Segment identity capture for export boundary and remove revalidation | `FileLogStoreRemoveStaleBoundaryTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `InternalReadError.swift` | Internal read failures and corruption-class mapping | `RecoverablePrefixScannerTests.swift`, `AcceptedLineIteratorTests.swift`, `CorpusRecoveryTests.swift` |
| `JSONDuplicateMemberScanner.swift` | Duplicate JSON member detection, including escaped-name equivalence | `JSONDuplicateMemberScannerTests.swift`, `CorpusRecoveryTests.swift` |
| `OperationBoundary.swift` | Nonreentrant operation-boundary serialization across append, flush, export, and removal, including lease-match hand-off safety, FIFO hand-off across multiple queued waiters, and non-cancelable queued-waiter semantics | `OperationBoundaryTests.swift`, `FileLogStoreExportTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift` |
| `RecoverablePrefixScanner.swift` | Recoverable-prefix discovery, recoverable-prefix boundary-only reopen, memory-bounded scanning | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerMemoryTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift`, `CorpusRecoveryTests.swift` |
| `RemovalBoundary.swift` | In-memory removal-boundary model and file identity state | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveStaleBoundaryTests.swift`, [`RemoveLifecycleSQECoverage.md`](RemoveLifecycleSQECoverage.md) |
| `RetentionPolicy.swift` | Retention policy validation, configuration storage, factory boundaries | `FileLogStoreRetentionTests.swift`, [`RetentionPolicySQECoverage.md`](RetentionPolicySQECoverage.md) |
| `RotationPolicy.swift` | Rotation policy validation and configuration storage | `FileLogStoreRotationTests.swift` |
| `FileLogStoreRetention.swift` | Whole-rotated-segment retention enforcement, active-segment exclusion, descriptor-relative deletion, post-seam candidate revalidation, overflow-safe `.maxTotalBytes` selection, `mtime`-driven `.maxAge` selection, and failure projection onto `.enforceRetention` | `FileLogStoreRetentionTests.swift`, `RetentionSelectionTests.swift`, [`RetentionPolicySQECoverage.md`](RetentionPolicySQECoverage.md) |
| `SegmentEnumeration.swift` | Segment filename parsing, numeric ordering, regular-file filtering, metadata failure mapping, ambiguous topology rejection, descriptor-relative discovery, configured-root TOCTOU rejection, duplicate-tracker order independence | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift`, `DuplicateRotatedSegmentTrackerTests.swift`, `SymlinkedConfiguredRootTests.swift`, `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift` |

## Test Infrastructure Closure Matrix

This table covers reusable test primitives whose behavior is part of the SQE
proof model. These helpers are not production API, but their contracts must be
reviewable because export/remove concurrency tests depend on them.

| Test primitive | Required closure proof | Primary test location |
| --- | --- | --- |
| `OperationBoundary` | Lease-match release, stale lease rejection during hand-off, FIFO hand-off across multiple queued waiters, non-cancelable queued-waiter semantics, and deterministic cleanup on failure paths. | `OperationBoundaryTests.swift` |
| `TestRendezvous` | Non-blocking async rendezvous, cancellation before and after waiter registration, multi-waiter broadcast for pause and release sides, timeout behavior for non-cancellation-cooperative inner operations, and no `DispatchSemaphore.wait` inside actor-isolated seams. | `TestRendezvousTests.swift`, `FileLogStoreExportTests.swift`, `FileLogStoreRemoveConcurrencyTests.swift` |
| Export temporary containment | Private temp containment, owner-only temporary and final export modes, no process-wide `umask` mutation, and parent-symlink fail-closed behavior. | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStorePermissionsTests.swift`, [`ByteStableExportSQECoverage.md`](ByteStableExportSQECoverage.md) |

## Maintenance Rules

- Keep this file as an index, not a second specification.
- Keep requirement IDs aligned with [`Docs/Requirements.md`](../../Docs/Requirements.md).
- When a listed requirement has a Swift Testing tag, at least one primary test
  for that row should carry the matching tag.
- Coverage maps MUST reside in the same directory as this index when coverage
  is distributed across multiple test suites or multiple contract areas.
- Do not mark a future area as covered until its implementation and tests land
  in the same milestone series.
- Link to focused test suites instead of listing every individual test.
