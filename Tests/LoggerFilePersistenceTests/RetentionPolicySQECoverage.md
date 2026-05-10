# Retention Policy SQE Coverage Map

This file maps retention coverage across the retention test suite
and contract areas to public retention semantics.
[`Docs/APIDesign.md`](../../Docs/APIDesign.md) owns
API-observable retention contracts.
[`Docs/Requirements.md`](../../Docs/Requirements.md) owns the `LGP-7`
identifier.

This document is non-normative and does not define behavior.

For the target-level index, see
[`CoverageMap.md`](CoverageMap.md).

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Public configuration surface | LGP-2, LGP-7 | `FileLogStoreRetentionTests.swift` | `RetentionPolicy` factories validate (`.maxSegments(0)` and `.maxTotalBytes(< maxEncodedLineBytes)` reject), boundary-equality factories accept, and `Configuration(directory:)` / `Configuration(directory:rotation:)` default `retention = .unlimited`. Explicit `retention` is round-tripped through `Configuration(directory:rotation:retention:)`. |
| `.unlimited` no-op enforcement | LGP-7, LGP-25, LGP-27 | `FileLogStoreRetentionTests.swift` | Five rotation-sized appends produce five rotated segments; topology and per-segment bytes match canonical encoder bytes byte-for-byte. |
| `.never` rotation no-op | LGP-7, LGP-25, LGP-27 | `FileLogStoreRetentionTests.swift` | Both `.maxSegments` and `.maxTotalBytes` under `.never` rotation leave `log.ndjson` byte-for-byte equal to concatenated canonical-encoded admitted lines and produce no rotated segment. |
| `.bySize` `.maxSegments` | LGP-7, LGP-25 | `FileLogStoreRetentionTests.swift` | Four appends under `.maxSegments(2)` retain only the two newest rotated segments (`log.000003` + `log.000004` active); three appends under `.maxSegments(1)` retain only the active segment. |
| `.bySize` `.maxTotalBytes` | LGP-7, LGP-25 | `FileLogStoreRetentionTests.swift` | Four appends under `.maxTotalBytes(2 × maxEncodedLineBytes)` drop the oldest until total ≤ cap; under a cap below two lines, deletion stops at the active writer segment. |
| Append cardinality preserved | LGP-7, LGP-11, LGP-25, LGP-27 | `FileLogStoreRetentionTests.swift` | After retention deletes older segments, the remaining rotated segment and the active segment carry the canonical bytes for the corresponding sequences byte-for-byte. |
| Export interaction | LGP-7, LGP-8, LGP-32 | `FileLogStoreRetentionTests.swift` | Export after retention concatenates canonical bytes for the retained segments only; older retention-deleted segments are not visible. |
| Remove interaction (stale boundary) | LGP-7, LGP-9 | `FileLogStoreRetentionTests.swift` | A successful export captures a boundary referencing segment `log.000001`; a follow-up append under `.maxSegments(2)` retention deletes that segment, after which `removeExportedLogs()` fails with `.removalBoundaryStale`. |
| Retention failure injection | LGP-2, LGP-7 | `FileLogStoreRetentionTests.swift` | An injected unlink failure surfaces `.operationFailed(.enforceRetention, url: <segment>, ...)`. The triggering append remains admitted; the segment retention attempted to unlink remains on disk; subsequent appends operate on the recoverable topology. |
| Descriptor-relative safety | LGP-2, LGP-7 | `FileLogStoreRetentionTests.swift` | A configured-path swap after writer-root acquisition (rename the original directory aside and recreate an empty replacement) does not redirect retention deletion. The originally configured directory observes retention and the post-swap configured-path directory remains untouched. |
| Candidate revalidation between seam and deletion | LGP-2, LGP-7 | `FileLogStoreRetentionTests.swift` | Retention revalidates each selected deletion candidate descriptor-relatively after the test seam fires, does not follow symlink replacements, and requires the candidate to still be a regular rotated segment before destructive deletion. A symlink replacement (`.maxSegments` path) or directory replacement (`.maxTotalBytes` path) between seam and deletion fails closed with `.operationFailed(.enforceRetention)`; the triggering append remains admitted, the planted replacement entry stays in place, and the symlink target's bytes remain unchanged. |
| Overflow-safe `.maxTotalBytes` selection | LGP-2, LGP-7 | `RetentionSelectionTests.swift` | Pure selection helper covers empty input, only-active retained, all-fit no-deletion, oldest-first deletion until cap fits, mid-segment cascade (newest-first priority), boundary equal/above headroom, active-segment-equal/over-cap clamps headroom, and pathological `UInt64.max` segment sizes plus `UInt64.max` cap without trapping or wrapping. |

## Review Checklist

- Whole-rotated-segment deletion only: retention never compacts a
  segment, splits a line, or deletes inside-segment bytes.
- Active writer segment is never deleted regardless of policy.
- `.unlimited` and `.never` enforcement paths are no-ops.
- Failure surface is `FileLogStoreError.operationFailed(.enforceRetention)`;
  admission of the triggering append is preserved.
- Descriptor-relative safety is reviewed through topology-state
  proofs after a configured-root swap, not through filename
  parsing.
- Candidate revalidation between seam and deletion is reviewed
  through observable failure-closed behavior: retention rejects a
  symlink or non-regular replacement before destructive deletion,
  does not follow symlinks, and leaves the replacement entry and
  any symlink target unchanged.
- `.maxTotalBytes` selection arithmetic is reviewed through pure
  unit tests over synthetic `UInt64` sizes — empty input, all-fit,
  oldest-first eviction, newest-first cascade, boundary equality,
  active-segment-over-cap clamp, and pathological `UInt64.max`
  candidate sizes plus `UInt64.max` cap — so the production path
  is reviewed through descriptor-metadata-to-helper mapping rather
  than through repeated filesystem-bound arithmetic proofs.
- No single test is expected to prove the entire retention contract
  alone.
