# Export And Remove Design

Non-normative design notes for the shipped byte-stable export contract
and the deferred destructive remove lifecycle. Locked API guarantees live in
`Docs/APIDesign.md`; file-format semantics live in `Docs/FileFormatSpec.md`.

## Status

The byte-stable export and export-serialization contracts are
implemented and locked. The remaining design questions are protocol
ownership and the destructive `removeExportedLogs()` lifecycle.

## Deferred Protocol Shape

```text
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
```

`ExportableLogStore` will remain separate from `PersistentLogStore`
so storage-only consumers, such as the M3.4 remote-delivery queue,
do not have to depend on export APIs they never use. The protocol
lands together with `removeExportedLogs()`; introducing the protocol
without the remove lifecycle would require adding a new protocol
requirement later, which is an API compatibility break.

## Resolved Export Serialization Questions (M3.3.2)

| Question | Resolution |
| --- | --- |
| Does `exportLogs(to:)` flush before reading? | No. Recoverable visibility is the durability boundary. Callers flush explicitly when they want export-after-flush. |
| Is the active segment included? | Yes, up to its recoverable-prefix boundary during the actor-isolated export operation. |
| What is the export serialization boundary against concurrent append operations? | Export executes as one actor-isolated operation without interleaving append, flush, or rotation operations. |

## Byte-Stable Export Format (locked)

Byte-stable export reproduces complete NDJSON envelope lines in
accepted ordering, without decoding payload bytes or re-encoding
envelopes. Any logical export format must use a separately named API
so callers know the export may normalize formatting or sort by
sequence.

Byte-stable export preserves accepted ordering. Rotated segment filename
order alone does not define replay/export ordering semantics.

## Duplicate Sequences (locked for byte-stable export)

Duplicate `sequence` values are exported verbatim without detection,
collapse, or tie-breaking.

Future logical export APIs may define duplicate-handling semantics
independently from byte-stable export.

## Remove Questions Under Evaluation

- whether `removeExportedLogs()` is safe only after successful export or
  after an explicit caller-owned decision
- atomicity against concurrent `append` and `exportLogs` operations
- whether removal blocks concurrent append or export operations
- whether removal uses a sequence boundary that is excluded from deletion
- how removal avoids deleting envelopes outside the approved
  removal boundary
