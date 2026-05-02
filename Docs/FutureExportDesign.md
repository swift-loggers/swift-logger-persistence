# Future Export Design

Non-contract design notes for the deferred M3.3.2 export/remove API.
Nothing in this document is public API in M3.3.0. The questions below are
under evaluation and need API/spec approval plus conformance proof before
`ExportableLogStore` lands.

## Expected Shape

```text
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
```

`ExportableLogStore` remains separate from `PersistentLogStore` so that
storage-only consumers, such as the M3.4 remote-delivery queue, do not
have to depend on export APIs they never use.

## Snapshot Questions Under Evaluation

- whether `exportLogs(to:)` flushes before reading
- whether the active segment is included, and if so
  which snapshot boundary prevents racing appends from producing a
  partial or reordered export
- how snapshot boundaries behave across segment rotation. If rotation
  occurs while export is running, the export design needs to
  define whether the pre-rotation segment, post-rotation segment, or both
  are included, while preserving accepted ordering
- whether appends can continue concurrently and whether they are
  excluded from, included in, or blocked by the snapshot

## Export Format

Current direction follows the locked file-format model: byte-stable
export reproduces the selected complete NDJSON envelope lines in
accepted ordering, without decoding payload bytes or re-encoding
envelopes. Any logical export format is a separately named API so
callers know it may normalize formatting or sort by sequence.

Accepted ordering is the byte-stable export order. Segment filename
order is not sufficient.

## Duplicate Sequences

Duplicate `sequence` values matter to future logical or
sequence-oriented exports. In the M3.3.2 shape sketched here, there is
no persisted producer-stream identifier, so duplicate detection is
scoped to the entire export snapshot.

If a future envelope version adds a producer-stream identifier, duplicate
detection may narrow to `(producerStreamID, sequence)` after the new
field's compatibility contract is specified.

Current direction does not silently collapse, deduplicate, or choose an
arbitrary order for duplicates. Before the API lands, the design needs to
choose between failing export with a typed error before writing partial
file or defining a deterministic tie-breaker that preserves every
duplicate line. Any tie-breaker that lands becomes a compatibility
contract and is under evaluation against undefined dictionary order,
filesystem enumeration order, and parser side effects.

## Remove Questions Under Evaluation

- whether `removeExportedLogs()` is safe only after successful export or
  after an explicit caller-owned decision
- atomicity against concurrent `append` and `exportLogs` operations
- whether removal blocks concurrent appends/exports or uses a sequence
  boundary that is excluded from deletion
- how the implementation avoids deleting an envelope that is being
  appended, being exported, or has not crossed the caller-approved
  removal boundary
