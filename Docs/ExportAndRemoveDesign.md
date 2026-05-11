# Export and Remove Design

Non-normative design notes for the shipped byte-stable export
contract, destructive remove lifecycle, and count-, byte-, and
age-based retention policy. Locked API guarantees live in
[`APIDesign.md`](APIDesign.md); file-format semantics live in
[`FileFormatSpec.md`](FileFormatSpec.md).

## Status

The byte-stable export, export-serialization, protocol ownership,
destructive remove, and count-, byte-, and age-based retention
contracts are implemented and locked.

## Protocol Shape (locked)

```text
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
```

`ExportableLogStore` remains separate from `PersistentLogStore` so
storage-only consumers, such as the M3.4 remote-delivery queue, do
not have to depend on export/remove APIs they never use. The protocol
lands together with `removeExportedLogs()` so the protocol does not
need a later requirement addition.

## Resolved Export Serialization Questions (M3.3.2)

| Question | Resolution |
| --- | --- |
| Does `exportLogs(to:)` flush before reading? | No. Recoverable visibility is the persistence contract boundary. Callers flush explicitly when they want export-after-flush. |
| Is the active segment included? | Yes, up to its recoverable-prefix boundary while `exportLogs(to:)` holds the nonreentrant operation boundary. |
| What is the export serialization boundary against concurrent append operations? | Export holds the nonreentrant operation boundary; concurrent append, flush, export, and removal callers wait until export releases that boundary. |

## Byte-Stable Export Format (locked)

Byte-stable export reproduces complete accepted lines in accepted
ordering, including LF delimiters, without decoding payload bytes or
re-encoding envelopes. Any logical export format must use a separately
named API so callers know the export may normalize formatting or sort
by sequence.

Byte-stable export preserves accepted ordering. Rotated segment filename
order alone does not define export ordering semantics or future replay
ordering semantics.

## Duplicate Sequences (locked for byte-stable export)

Duplicate `sequence` values are exported verbatim without detection,
collapse, or tie-breaking.

Future logical export APIs may define duplicate-handling semantics
independently from byte-stable export through separately named APIs.

## Resolved Removal Questions (M3.3.2)

| Question | Resolution |
| --- | --- |
| When is removal allowed? | Only after a successful `exportLogs(to:)` captures an in-memory boundary. Failed export does not create or advance the boundary. |
| What does removal delete? | Removal deletes exported prefix bytes and preserves accepted bytes admitted after the successful export destination commit byte-for-byte without normalization or re-encoding. |
| What happens after restart? | The in-memory boundary is lost; `removeExportedLogs()` fails with `.noExportedRemovalBoundary`. |
| How does removal serialize with concurrent work? | Removal holds the nonreentrant operation boundary while processing the removal boundary; concurrent append, flush, export, and removal callers wait until removal releases that boundary. |
| How are active writer segments handled? | Active segments are reset or compacted through writer-owned coordination, then appends continue after the preserved removal boundary. |
| How does failure retry work? | Completed destructive segment steps are not retried. After partial destructive progress, the remaining in-memory boundary is retained for retry and cleared only after full success. |
| How are stale boundaries handled? | Missing segments, identity mismatch, insufficient size, and ambiguous rotated topology fail closed as `.removalBoundaryStale`. |

## Retention Policy

Retention is an append-triggered destructive lifecycle operation,
not a downstream step after `removeExportedLogs()`. Count-, byte-,
and age-cap retention (`.maxSegments`, `.maxTotalBytes`,
`.maxAge(seconds:)`) ship in M3.3.2: retention runs after a
successful append admission without rolling back the admitted append
on retention failure, holds the same nonreentrant operation boundary
append already holds, and deletes whole rotated segments only —
never the active writer segment, never inside-segment prefix bytes.
Age retention reads filesystem `mtime` via
`fstatat(AT_SYMLINK_NOFOLLOW)`; it does not parse envelope payloads
or accepted-line timestamps and does not depend on calendar/DST
math.
