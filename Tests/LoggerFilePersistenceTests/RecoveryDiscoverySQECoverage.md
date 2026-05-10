# Recovery Discovery SQE Coverage Map

This file maps recovery-discovery coverage across test suites
and contract areas to recovery-discovery semantics defined in
[`Docs/FileFormatSpec.md`](../../Docs/FileFormatSpec.md).
[`Docs/FileFormatSpec.md`](../../Docs/FileFormatSpec.md) remains the
sole normative file-format contract owner.

This document is non-normative and does not define behavior.

For the target-level index, see
[`CoverageMap.md`](CoverageMap.md).

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Segment discovery and ordering | LGP-6, LGP-39 | `SegmentEnumerationTests.swift`, `SegmentEnumerationLinearScanTests.swift`, `SegmentEnumerationLstatFailureTests.swift` | Rotated segments are selected by numeric sequence, not lexical filename or filesystem enumeration order. Non-regular matching entries are filtered, and metadata failures surface as typed enumeration errors. |
| Envelope line classification | LGP-33, LGP-34, LGP-35, LGP-38 | `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift`, `JSONDuplicateMemberScannerTests.swift` | LF-terminated lines are classified as accepted or interior corruption using corpus-governed categories, including duplicate JSON members. |
| Corpus-governed corruption classes | LGP-33, LGP-34, LGP-35, LGP-36, LGP-37 | `CorpusRecoveryTests.swift` and `Fixtures/Corpus/` | Each released fixture maps byte-for-byte to the expected corruption class or recovery outcome. |
| Recoverable-prefix scanning | LGP-14, LGP-15, LGP-16, LGP-17, LGP-18 | `RecoverablePrefixScannerTests.swift`, `RecoverablePrefixScannerMemoryTests.swift` | Discovery starts at byte zero, accepts only valid LF-terminated envelope lines, excludes trailing partial bytes, and hard-stops on interior corruption. |
| Boundary-only writer reopen | LGP-14, LGP-15, LGP-16, LGP-17, LGP-24, LGP-25 | `RecoverablePrefixScannerBoundaryTests.swift`, `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift` | Writer reopen resolves the recoverable-prefix boundary, does not require materialized accepted-line state, truncates only trailing partial bytes, and fails closed on interior corruption. |
| No production array scanner path | LGP-14, LGP-16, LGP-18 | `RecoverablePrefixScannerBoundaryTests.swift`, `RecoverablePrefixScannerCollectHelper.swift` | Production APIs expose pull iteration and boundary resolution only; materialized collection helpers are test-only. |
| Accepted-line iteration policy | LGP-6, LGP-14, LGP-27 | `AcceptedLineIteratorTests.swift`, `SegmentEnumerationLinearScanTests.swift` | `.never` reads only `log.ndjson`; `.bySize` reads rotated segments by numeric sequence; policies are not blended. |
| Accepted ordering and byte stability | LGP-27, LGP-30, LGP-31 | `AcceptedLineIteratorTests.swift`, `CanonicalEnvelopeLineEncoderTests.swift`, `FileLogStoreExportReplayIdentityTests.swift` | Accepted bytes, including the LF delimiter, are yielded byte-for-byte in accepted ordering across segment boundaries. Replay identity holds for unknown future `contentType` values: no `contentType`-specific payload interpretation, upgrade, or export re-encoding determines the yielded or exported bytes; unknown `contentType` remains opaque end-to-end on both the accepted-line iterator path and the byte-stable export path. |
| Trailing partial exclusion | LGP-14, LGP-15, LGP-16 | `AcceptedLineIteratorTests.swift`, `AcceptedLineIteratorMidChainPartialTests.swift`, `RecoverablePrefixScannerTests.swift` | Bytes after the recoverable prefix are excluded from read output. Non-final trailing partial bytes hard-stop before later segments. |
| Interior corruption hard-stop | LGP-17, LGP-35, LGP-37 | `AcceptedLineIteratorTests.swift`, `RecoverablePrefixScannerTests.swift`, `CorpusRecoveryTests.swift` | The first interior corruption stops iteration at its boundary; later accepted lines or later segments are not visible. |
| Pull-based laziness and backpressure | LGP-14, LGP-16, LGP-18, LGP-19 | `AcceptedLineIteratorPullStreamingTests.swift`, `AcceptedLineIteratorCancellationTests.swift`, `RecoverablePrefixScannerBoundaryTests.swift` | The accepted-line iterator checks cancellation between yielded accepted lines; boundary resolution does not introduce cancellation-observable accepted bytes or ordering changes. |
| File-store reopen lifecycle | LGP-14, LGP-15, LGP-16, LGP-17, LGP-24, LGP-25, LGP-39 | `FileLogStoreReopenTests.swift`, `FileLogStoreReopenDuplicateTests.swift` | Reopen resumes at the recoverable-prefix boundary, preserves accepted bytes, rejects ambiguous topology, and keeps failed reopen non-destructive. |
| Descriptor-relative discovery / TOCTOU rejection | LGP-2, LGP-14, LGP-24, LGP-25 | `AcceptedLineIteratorMidScanTOCTOUTests.swift`, `FileLogStoreWriterMidScanTOCTOUTests.swift`, `SymlinkedConfiguredRootTests.swift` | The iterator and writer hold a descriptor-relative root handle across discovery and descriptor acquisition. Read-side path swaps fail closed before reading replacement-root bytes. Write-side root swaps fail closed before descriptor acquisition. Writes continue through the held descriptor after acquisition without mutating the replacement root. |

## Review Checklist

- Corruption classification is reviewed through corpus tests, not iterator tests.
- Accepted-line iteration behavior is reviewed through accepted-line policy tests.
- Discovery ordering is reviewed through numeric-sequence topology tests, not filesystem enumeration order.
- Streaming and backpressure are reviewed through pull-streaming tests.
- Writer reopen behavior is reviewed through recoverable-prefix boundary-resolution tests.
- Boundary-only reopen is reviewed through recoverable-prefix boundary tests, not materialized accepted-line arrays.
- Replay identity is reviewed through accepted-byte preservation across segment boundaries and through unknown-`contentType` opacity on both the accepted-line iterator path and the byte-stable export path. No `contentType`-specific payload interpretation, upgrade, or export re-encoding determines the yielded or exported bytes.
- No single test file is expected to prove the entire recovery contract alone.
