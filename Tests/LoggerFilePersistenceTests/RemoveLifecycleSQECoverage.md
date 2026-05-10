# Remove Lifecycle SQE Coverage Map

This file maps destructive-removal coverage across test suites
and contract areas to remove lifecycle semantics.
[`Docs/APIDesign.md`](../../Docs/APIDesign.md) owns
API-observable remove contracts.
[`Docs/FileFormatSpec.md`](../../Docs/FileFormatSpec.md) owns
accepted-byte and recoverable-prefix contracts.

This document is non-normative and does not define behavior.

For the target-level index, see
[`CoverageMap.md`](CoverageMap.md).

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Public remove surface | LGP-2, LGP-9 | `FileLogStoreRemoveTests.swift` | `ExportableLogStore` exposes the untyped export/remove protocol surface, while `FileLogStore.removeExportedLogs()` exposes the concrete typed remove error surface. Calling remove without a successful export fails as `.noExportedRemovalBoundary` and performs no filesystem mutation. |
| Boundary capture and consumption | LGP-8, LGP-9, LGP-24, LGP-25 | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveFailureTests.swift` | Successful export captures the in-memory removal boundary only after the export commit succeeds. Failed export does not capture a boundary. Successful remove clears the boundary; partial failure retains only the remaining boundary tail for retry. |
| Prefix deletion and suffix preservation | LGP-9, LGP-14, LGP-27 | `FileLogStoreRemoveTests.swift` | `.never` removal deletes exported prefix bytes and preserves post-boundary accepted bytes byte-for-byte. Regression coverage proves remove preserves the post-boundary suffix byte-for-byte and never truncates to `exportedPrefixEnd`. |
| Rotated segment removal mechanics | LGP-6, LGP-9, LGP-27, LGP-39 | `FileLogStoreRemoveTests.swift` | Fully exported non-active rotated segments are unlinked; the active rotated segment preserves no accepted bytes before the removal boundary and remains writable for subsequent appends. Rotated segments with post-boundary bytes are compacted so the suffix survives byte-for-byte. |
| Active writer lifecycle | LGP-9, LGP-25, LGP-27 | `FileLogStoreRemoveTests.swift`, `FileLogStoreRemoveFailureTests.swift` | After reset or compaction of the active segment, subsequent append continues after the preserved removal boundary. Failure after a destructive active-segment mutation advances the boundary past that entry before retry. |
| Stale boundary fail-closed | LGP-2, LGP-9, LGP-24, LGP-25, LGP-39 | `FileLogStoreRemoveStaleBoundaryTests.swift` | Missing boundary segment, symlink replacement, identity mismatch, segment size shorter than `exportedPrefixEnd`, post-validation disappearance or symlink swap, and duplicate numeric rotated topology each fail as `.removalBoundaryStale` before mutating the affected entry. |
| Failure and retry | LGP-9, LGP-24, LGP-25 | `FileLogStoreRemoveFailureTests.swift` | Per-entry failure retains the unprocessed boundary tail and retry completes the remaining entries. Active-writer recovery failures after destructive mutation do not force retry to revalidate already-mutated entries. |
| Deferred-close discipline | LGP-9, LGP-24, LGP-25 | `FileLogStoreRemoveTests.swift` | Removal drains the actor-owned pending-close queue before processing the removal boundary, matching the deferred-close discipline used by append, flush, and export. |
| Serialization | LGP-9, LGP-19, LGP-24, LGP-25 | `FileLogStoreRemoveConcurrencyTests.swift`, `OperationBoundaryTests.swift` | Concurrent append and export tests use deterministic async rendezvous seams plus operation-boundary proofs to prove remove holds the nonreentrant operation boundary and does not interleave `append`, `exportLogs(to:)`, or remove execution. |

## Review Checklist

- Boundary semantics are reviewed through exported-prefix removal
  and post-boundary suffix-preservation tests, not through
  implementation comments.
- Retry behavior is reviewed through failure-after-progress tests, not through a single all-success path.
- Deferred-close discipline is reviewed through explicit
  pending-close queue drain tests, not by assuming another public
  operation will eventually drain the queue.
- Active writer lifecycle is reviewed through post-remove append and post-mutation failure tests.
- Stale-boundary safety is reviewed through identity, topology, and size mismatch tests.
- Serialization is reviewed through deterministic contention tests,
  not timing sleeps.
- Serialization review is based on observable nonreentrant
  operation-boundary behavior, not actor implementation inspection.
- No single test file is expected to prove the entire remove contract alone.
