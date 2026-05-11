# Byte-Stable Export SQE Coverage Map

This file maps byte-stable export coverage across test suites and
contract areas to byte-stable export semantics.
[`Docs/FileFormatSpec.md`](../../Docs/FileFormatSpec.md) owns
file-format contracts.
[`Docs/APIDesign.md`](../../Docs/APIDesign.md) owns
API-observable contracts.

This document is non-normative and does not define behavior.

For the target-level index, see
[`CoverageMap.md`](CoverageMap.md).

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Public export surface | LGP-8, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStoreExportRotatedTests.swift` | `FileLogStore.exportLogs(to:)` is the concrete typed byte-stable export API. `ExportableLogStore` exposes the portable untyped export/remove protocol surface. |
| Destination topology rejection (no-overwrite) | LGP-2, LGP-8, LGP-32 | `FileLogStoreExportDestinationTests.swift`, `FileLogStorePermissionsTests.swift` | Existing regular file, symlink, directory, FIFO (non-regular), absent parent, parent-is-regular-file, and parent-is-symlink each map to a distinct `FileLogStoreExportError.invalidDestination` reason. The pre-existing entry is byte-unmodified after the rejected export. A symlink at the destination parent path is rejected as `.parentDirectoryInvalid` and the symlink target directory is not written to. |
| Caller-input destination URL validation | LGP-2, LGP-8, LGP-32 | `FileLogStoreExportDestinationTests.swift` | A non-file destination URL is rejected as `.operationFailed(.validateDestination, url: originalURL, context: ...)` before any path-based derivation runs. |
| Atomic commit | LGP-8, LGP-24, LGP-25, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift` | Export-created final bytes are materialized only after temp-byte durability and no-overwrite atomic commit succeed. Interior corruption mid-scan, write-failure-seam injection, close-failure-seam injection, and a destination materialized between pre-check and commit leave the final URL untouched or preserve the planted destination. Covered failure-seam tests observe no temp leftover; API cleanup remains best-effort against filesystem failure. |
| Export temporary confidentiality and permissions | LGP-8, LGP-24, LGP-25, LGP-32 | `FileLogStoreExportTests.swift` | Export confines payload bytes to a private temporary directory (`0o700`) inside the destination parent; no readable regular temp file is exposed during the write phase. The export payload temp file is created owner-only (`0o600`) — the mode is enforced descriptor-relative via an explicit `fchmod` permission-preservation step after `openat`, so a process umask that would mask owner bits cannot weaken the on-disk mode below `0o600`. The atomic rename preserves that mode on the final destination — the writer-private contract does not depend on the process umask. Covered failure paths observe no leftover payload or private temp directory; cleanup remains best-effort against filesystem failure. Export performs no process-wide permission-state mutation. |
| Byte-stable export bytes | LGP-8, LGP-27, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | Multi-segment `.bySize` and single-segment `.never` exports concatenate accepted bytes verbatim in accepted ordering. Trailing partial bytes are excluded for both `.never` (single segment) and `.bySize` (trailing partial in the latest rotated segment). The output ends with the last accepted line's LF; no extra terminator or footer is appended. Duplicate `sequence` values are preserved in accepted ordering. |
| Single-flight serialization | LGP-8, LGP-19, LGP-24, LGP-25, LGP-32 | `FileLogStoreExportTests.swift`, `OperationBoundaryTests.swift` | Concurrent export-against-append tests verify nonreentrant operation-boundary export behavior and stable accepted-byte export results. |
| Empty recoverable prefix | LGP-8, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | A `.never` store with no admitted lines and a `.bySize` store with no rotated segments each export a 0-byte file at the destination URL; the call returns successfully, no error variant is raised. |
| Interior corruption hard-stop in export | LGP-8, LGP-17, LGP-32, LGP-35, LGP-37 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | Interior corruption mid-scan aborts the export, projects to `FileLogStoreExportError.interiorCorruption` with the matching `FileLogStoreExportCorruptionClass`, and leaves the destination absent. Coverage spans single-segment `.never` and multi-segment `.bySize` (corruption in a non-terminal rotated segment); the segment URL reported in the error matches the corrupted segment, and covered paths observe no temp leftover in the destination parent. |
| Replay identity for unknown `contentType` | LGP-8, LGP-27, LGP-30, LGP-31, LGP-32 | `FileLogStoreExportReplayIdentityTests.swift` | An admitted envelope whose `contentType` is outside any package-known profile is exported byte-for-byte, including the LF delimiter, in accepted ordering. Coverage spans `.never` (single segment) and `.bySize` (multiple rotated segments + active). No `contentType`-specific payload interpretation, upgrade, or export re-encoding determines the exported bytes; unknown `contentType` remains opaque end-to-end. |

## Review Checklist

- Atomicity is reviewed through commit-failure / cleanup tests, not byte-content tests.
- Export temporary confidentiality is reviewed through temp
  topology, permission, cleanup, and no-process-wide-state checks,
  not through final-byte equality alone.
- Byte content is reviewed through byte-exact concatenation tests.
- Single-flight serialization is reviewed through observable
  nonreentrant operation-boundary behavior, not actor
  implementation details.
- Replay identity is reviewed through accepted-byte preservation
  across segment boundaries (including the LF delimiter) and
  through unknown-`contentType` opacity along the export path.
  No `contentType`-specific payload interpretation, upgrade, or
  export re-encoding determines the exported bytes.
- No single test is expected to prove the entire export contract alone.
