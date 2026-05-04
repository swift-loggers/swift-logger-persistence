# M3.3.2 Recovery Discovery SQE Coverage Map

This file maps M3.3.2 recovery-discovery coverage across test suites
and contract areas.
Docs/FileFormatSpec.md remains the normative contract owner.

This document is non-normative and does not define behavior.

For the target-level index, see `CoverageMap.md`.

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Segment discovery and ordering | LGP-6, LGP-39 | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift` | Rotated segments are selected by numeric segment index, not lexical filename or filesystem enumeration order. Non-regular matching entries are filtered, and metadata failures surface as typed enumeration errors. |
| Envelope line classification | LGP-33, LGP-34, LGP-35, LGP-38 | `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift`, `JSONDuplicateMemberScannerTests.swift` | LF-terminated lines are classified as accepted or interior corruption using corpus-governed categories, including duplicate JSON members. |
| Corpus-governed corruption classes | LGP-33, LGP-34, LGP-35, LGP-36, LGP-37 | `CorpusRecoveryTests.swift` and `Fixtures/Corpus/` | Each released fixture maps byte-for-byte to the expected corruption class or recovery outcome. |
| Recoverable-prefix scanning | LGP-14, LGP-15, LGP-16, LGP-17, LGP-18 | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerMemoryTests.swift` | Discovery starts at byte zero, accepts only valid LF-terminated envelope lines, excludes trailing partial bytes, and hard-stops on interior corruption. |
| Boundary-only writer reopen | LGP-14, LGP-15, LGP-16, LGP-17, LGP-24, LGP-25 | `RecoverablePrefixScannerBoundaryTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift` | Writer reopen uses `resolveBoundary`, does not collect one outcome per accepted line, truncates only trailing partial bytes, and fails closed on interior corruption. |
| No production array scanner path | LGP-14, LGP-16, LGP-18 | `RecoverablePrefixScannerBoundaryTests.swift`, `RecoverablePrefixScannerCollectHelper.swift` | Production APIs expose pull iteration and boundary resolution only; materialized collection helpers are test-only. |
| Accepted-line iteration policy | LGP-6, LGP-14, LGP-27 | `AcceptedLineIteratorTests.swift`, `SegmentEnumerationLinearScanTests.swift` | `.never` reads only `log.ndjson`; `.bySize` reads rotated segments by numeric segment index; policies are not blended. |
| Accepted ordering and byte stability | LGP-27, LGP-30 | `AcceptedLineIteratorTests.swift`, `CanonicalEnvelopeLineEncoderTests.swift` | Accepted bytes are yielded byte-for-byte in accepted ordering, including across segment boundaries and for unknown `contentType` values. |
| Trailing partial exclusion | LGP-14, LGP-15, LGP-16 | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `RecoverablePrefixScannerTests.swift` | Bytes after the recoverable prefix are excluded from read output. Non-final trailing partial bytes hard-stop before later segments. |
| Interior corruption hard-stop | LGP-17, LGP-35, LGP-37 | `AcceptedLineIteratorTests.swift`, `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift` | The first interior corruption stops iteration at its boundary; later accepted lines or later segments are not visible. |
| Pull-based laziness and backpressure | LGP-14, LGP-16, LGP-18, LGP-19 | `AcceptedLineIteratorPullStreamingTests.swift`, `AcceptedLineIteratorCancellationTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift` | The accepted-line iterator checks cancellation between pull steps; scanner boundary resolution remains cancellation-neutral. |
| File-store reopen lifecycle | LGP-14, LGP-15, LGP-16, LGP-17, LGP-24, LGP-25, LGP-39 | `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift` | Reopen resumes at the recoverable-prefix boundary, preserves accepted bytes, rejects ambiguous topology, and keeps failed reopen non-destructive. |
| Descriptor-relative discovery / TOCTOU rejection | LGP-2, LGP-14, LGP-24, LGP-25 | `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `SymlinkedConfiguredRootTests.swift` | The iterator and writer hold an `O_NOFOLLOW` root descriptor across discovery and segment open. Read-side path swaps fail closed before reading attacker-controlled bytes. Write-side root swaps fail closed before descriptor acquisition and continue writing through the held descriptor after acquisition without mutating the replacement root. |

## Review Checklist

- Corruption classification is reviewed through corpus tests, not iterator tests.
- Iterator behavior is reviewed through accepted-line policy tests.
- Streaming and backpressure are reviewed through pull-streaming tests.
- Writer reopen memory shape is reviewed through boundary-resolution tests.
- No single test file is expected to prove the entire recovery contract alone.
