# M3.3.2 Byte-Stable Export SQE Coverage Map

This file maps M3.3.2 byte-stable export coverage across test suites
and contract areas to byte-stable export contracts.
Docs/FileFormatSpec.md owns file-format contracts.
Docs/APIDesign.md owns API-observable export guarantees.

This document is non-normative and does not define behavior.

For the target-level index, see CoverageMap.md.

## Coverage Matrix

| Contract area | Requirement IDs | Primary coverage | Closure proof |
| --- | --- | --- | --- |
| Public export surface | LGP-8, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift`, `FileLogStoreExportRotatedTests.swift` | `FileLogStore.exportLogs(to:)` is the only M3.3.2 byte-stable export API; no `ExportableLogStore` protocol and no `removeExportedLogs()` are exposed. |
| Destination topology rejection (no-overwrite) | LGP-2, LGP-8, LGP-32 | `FileLogStoreExportDestinationTests.swift` | Existing regular file, symlink, directory, FIFO (non-regular), absent parent, and parent-is-regular-file each map to a distinct `FileLogStoreExportError.invalidDestination` reason. The pre-existing entry is byte-unmodified after the rejected export. |
| Caller-input destination URL validation | LGP-2, LGP-8, LGP-32 | `FileLogStoreExportDestinationTests.swift` | A non-file destination URL is rejected as `.operationFailed(.validateDestination, url: originalURL, context: ...)` with `FileSystemErrorContext.packageDomain` and `code: nil` before any path-based derivation runs. |
| Atomic commit | LGP-8, LGP-24, LGP-25, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportDestinationTests.swift` | Export-created final bytes are materialized only after temp-byte durability and no-overwrite atomic commit succeed. Interior corruption mid-scan, write-failure-seam injection, close-failure-seam injection (`.operationFailed(.closeTemporaryDestination)` after the temp descriptor is consumed to prevent a second close), and a destination materialized between pre-check and commit leave the final URL untouched or preserve the planted destination. Covered failure-seam tests observe no temp leftover; API cleanup remains best-effort against filesystem failure. |
| Byte-stable export bytes | LGP-8, LGP-27, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | Multi-segment `.bySize` and single-segment `.never` exports concatenate accepted bytes verbatim in accepted ordering. Trailing partial bytes are excluded for both `.never` (single segment) and `.bySize` (trailing partial in the latest rotated segment). The output ends with the last accepted line's LF; no extra terminator or footer is appended. Duplicate `sequence` values are preserved in accepted ordering. |
| Single-flight serialization | LGP-8, LGP-19, LGP-24, LGP-25, LGP-32 | `FileLogStoreExportTests.swift` | Concurrent export-against-append tests verify actor-serialized export behavior and that the segment file remains canonical. |
| Empty recoverable prefix | LGP-8, LGP-32 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | A `.never` store with no admitted lines and a `.bySize` store with no rotated segments each export a 0-byte file at the destination URL; the call returns successfully, no error variant is raised. |
| Interior corruption hard-stop in export | LGP-8, LGP-17, LGP-32, LGP-35, LGP-37 | `FileLogStoreExportTests.swift`, `FileLogStoreExportRotatedTests.swift` | Interior corruption mid-scan aborts the export, projects to `FileLogStoreExportError.interiorCorruption` with the matching `FileLogStoreExportCorruptionClass`, and leaves the destination absent. Coverage spans single-segment `.never` and multi-segment `.bySize` (corruption in a non-terminal rotated segment); the segment URL reported in the error matches the corrupted segment, and covered paths observe no temp leftover in the destination parent. |

## Review Checklist

- Atomicity is reviewed through commit-failure / cleanup tests, not byte-content tests.
- Byte content is reviewed through byte-exact concatenation tests.
- Single-flight is reviewed through the concurrent-append test, not by inspecting actor implementation.
- No single test is expected to prove the entire export contract alone.
