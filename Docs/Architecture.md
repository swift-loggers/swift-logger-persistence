# Architecture

Non-normative system map for `swift-logger-persistence`.

## Scope

Layer map for package-local persistence APIs and file-backed storage.
Normative durability contract lives in `FileFormatSpec.md`.

### M3.3.0 target shape

M3.3.0 establishes the package-local persistence API and file-backed
storage shape.

- `PersistentLogEnvelope` value type
- `PersistentLogStore`
- `LogRecordPersistentEncoder`
- `FileLogStore`
- Replay APIs are outside the M3.3.0 target.

### Later milestones

- Byte-stable export lands in M3.3.2.

### Boundaries for later work

Deferred APIs and roadmap ordering live in `README.md` and
`ExportAndRemoveDesign.md`.

## Non-goals

- Remote retry/backoff.
- Vendor request building.
- Network delivery.
- Exactly-once delivery.
- Storing raw sensitive data by default.

## Layering

- API layer: `APIDesign.md`.
- Format/spec layer: `FileFormatSpec.md`.
- Compatibility layer: `APICompatibility.md`.
- Implementation layer: `Sources/` and `Tests/`.

For persistence contract, the format/spec layer outranks API prose.

## Package & product split

The target package shape has two products:

- `LoggerPersistence` -- protocols, envelope model, and record-aware
  encoder.
- `LoggerFilePersistence` -- file-backed implementation
  (`FileLogStore`, `FileLogStore.Configuration`).

See `Decisions/0001-package-split.md`.

## Logical view

```
Logger adapter
   |
   v
encoder/redactor (LogRecordPersistentEncoder, or caller-owned)
   |
   v
PersistentLogEnvelope
   |
   v
PersistentLogStore  (protocol)
   |
   v
FileLogStore        (concrete store; file-backed accepted-line persistence)
```

The companion PlantUML diagram is non-normative and mirrors this
layer map for visual review
([source](Resources/PersistenceLogicalView.puml)).

[![Persistence logical view](Resources/PersistenceLogicalView.svg)](Resources/PersistenceLogicalView.svg)

Ownership boundaries:

- The **adapter** is upstream and out of scope for this package.
- The **encoder** owns redaction and sequence assignment.
- The **envelope** is the target write unit accepted by stores.
- The **store** owns local file I/O, not payload decoding or vendor
  delivery.
- Replay file-format contract and byte-stable export contract live in
  `FileFormatSpec.md`.
- Stores preserve producer sequence metadata without assigning it.

See `Decisions/0002-envelope-storage.md` and
`Decisions/0004-ordering-model.md`.

## Failure model

Target storage APIs are `async throws`; concrete stores may narrow
their contracts with typed throws. Logger-facing adapters remain
infallible. Adapter diagnostics are non-normative and
non-authoritative, and adapter retry policy is outside the persistence
contract. See `Decisions/0005-failure-model.md`.
