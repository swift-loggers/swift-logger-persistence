# LoggerFilePersistence Coverage Map

This file maps `LoggerFilePersistence` contract areas to requirement IDs and
test coverage.

This document is non-normative and does not define behavior.
Docs/FileFormatSpec.md remains the sole normative file-format contract owner.
Docs/Requirements.md owns requirement IDs.

## Coverage Index

| Contract area | Requirement IDs | Status | Primary test location |
| --- | --- | --- | --- |
| Canonical envelope-line encoding | LGP-20, LGP-21, LGP-23, LGP-26, LGP-27, LGP-29 | Covered | `CanonicalEnvelopeLineEncoderTests.swift` |
| Envelope validation and encoded-line caps | LGP-2, LGP-22, LGP-38 | Covered | `FileLogStoreTests.swift`, `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift` |
| Encoded-line shape invariants | LGP-24, LGP-25, LGP-26 | Covered | `FileLogStoreTests.swift`, `CanonicalEnvelopeLineEncoderTests.swift` |
| Append/write path | LGP-1, LGP-11, LGP-24, LGP-25, LGP-27 | Covered | `FileLogStoreTests.swift` |
| Flush and file-handle lifecycle | LGP-5, LGP-12 | Covered | `FileLogStoreTests.swift`, `FileLogStoreReopenTests.swift` |
| Configuration and rotation-policy validation | LGP-2, LGP-6 | Covered | `FileLogStoreRotationTests.swift` |
| Size-based rotation | LGP-6, LGP-39 | Covered | `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift` |
| Rotation filename topology | LGP-6, LGP-39 | Covered | `FileLogStoreRotationTests.swift`, `SegmentEnumerationTests.swift` |
| Segment enumeration | LGP-6, LGP-39 | Covered | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift`, `DuplicateRotatedSegmentTrackerTests.swift` |
| Non-regular and ambiguous segment topology | LGP-2, LGP-6, LGP-39 | Covered | `SegmentEnumerationTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift`, `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `FileLogStoreWriterSymlinkTests.swift` |
| Public store error and invariant mapping | LGP-2, LGP-24, LGP-25, LGP-38, LGP-39 | Covered | `FileLogStoreTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreWriterSymlinkTests.swift` |
| Internal read error and corruption-class mapping | LGP-16, LGP-17, LGP-18, LGP-33, LGP-35, LGP-36, LGP-37 | Covered | `SegmentEnumerationLstatFailureTests.swift`, `RecoveryDiscoverySQECoverage.md`, `CorpusRecoveryTests.swift` |
| Duplicate JSON member detection | LGP-33, LGP-34, LGP-35 | Covered | `JSONDuplicateMemberScannerTests.swift`, `CorpusRecoveryTests.swift` |
| Recovery discovery | LGP-14, LGP-15, LGP-16, LGP-17, LGP-18, LGP-36, LGP-37 | Covered | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift`, `CorpusRecoveryTests.swift`, `RecoveryDiscoverySQECoverage.md` |
| Accepted-line iteration | LGP-14, LGP-15, LGP-19, LGP-27, LGP-30 | Covered | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `AcceptedLineIteratorPullStreamingTests.swift`, `AcceptedLineIteratorCancellationTests.swift`, `RecoverablePrefixScannerTests.swift`, `RecoveryDiscoverySQECoverage.md` |
| Corpus-governed corruption classification | LGP-33, LGP-34, LGP-35, LGP-36, LGP-37 | Covered | `RecoveryDiscoverySQECoverage.md`, `Fixtures/Corpus/` |
| Retention/removal | LGP-7, LGP-9 | Future scope | Not expected in M3.3.2 |
| Byte-stable export API | LGP-8, LGP-32 | Future scope | Not expected in M3.3.2 |
| Logical export API | LGP-32 | Future scope | Not expected in M3.3.2 |

## Implementation File Index

This table maps every current source file in `Sources/LoggerFilePersistence` to
its primary SQE coverage. It is an index only; the contract-area table above
remains the review entry point.

| Source file | Covered contract areas | Primary test location |
| --- | --- | --- |
| `AcceptedLineIterator.swift` | Accepted-line iteration, policy routing, accepted ordering, byte stability, pull-based laziness | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `AcceptedLineIteratorPullStreamingTests.swift`, `RecoveryDiscoverySQECoverage.md` |
| `CanonicalEnvelopeLineEncoder.swift` | Canonical envelope-line encoding, delimiter ownership, encoded-line byte shape | `CanonicalEnvelopeLineEncoderTests.swift`, `FileLogStoreTests.swift` |
| `EnvelopeLineClassifier.swift` | Read-side envelope validation and corruption classification | `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift` |
| `FileLogStore.swift` | Append/write path, flush, rotation, reopen, trailing-suffix handling, lifecycle seams, descriptor-relative writer opens | `FileLogStoreTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `FileLogStoreWriterSymlinkTests.swift` |
| `FileLogStoreError.swift` | Public store errors, validation errors, invariant mapping, filesystem error context projection | `FileLogStoreTests.swift`, `FileLogStoreRotationTests.swift`, `FileLogStoreReopenTests.swift` |
| `InternalReadError.swift` | Internal read failures and corruption-class mapping | `RecoverablePrefixScannerTests.swift`, `AcceptedLineIteratorTests.swift`, `CorpusRecoveryTests.swift` |
| `JSONDuplicateMemberScanner.swift` | Duplicate JSON member detection, including escaped-name equivalence | `JSONDuplicateMemberScannerTests.swift`, `CorpusRecoveryTests.swift` |
| `RecoverablePrefixScanner.swift` | Recoverable-prefix discovery, boundary-only reopen, memory-bounded scanning | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerMemoryTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift`, `CorpusRecoveryTests.swift` |
| `RotationPolicy.swift` | Rotation policy validation and configuration storage | `FileLogStoreRotationTests.swift` |
| `SegmentEnumeration.swift` | Segment filename parsing, numeric ordering, regular-file filtering, metadata failure mapping, ambiguous topology rejection, descriptor-relative discovery, duplicate-tracker order independence | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift`, `DuplicateRotatedSegmentTrackerTests.swift`, `AcceptedLineIteratorTests.swift`, `FileLogStoreReopenTests.swift` |

## Maintenance Rules

- Keep this file as an index, not a second specification.
- Keep requirement IDs aligned with Docs/Requirements.md.
- When a listed requirement has a Swift Testing tag, at least one primary test
  for that row should carry the matching tag.
- Coverage maps must reside in the same directory as this index when coverage
  is distributed across multiple test suites or multiple contract areas.
- Do not mark a future area as covered until its implementation and tests land.
- Prefer linking to focused test suites over listing every individual test.
