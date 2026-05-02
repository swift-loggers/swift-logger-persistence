# swift-logger-persistence

Local durable persistence primitives for [`swift-loggers`](https://github.com/swift-loggers):
an adapter-agnostic envelope/store contract plus a planned file-backed
implementation.

SwiftPM and platform deployment metadata will land with the
implementation PR that adds `Package.swift`. MIT licensed.

> **API in active design.** This pre-1.0 package is not tagged yet.

## Products

The planned package shape has two products:

- `LoggerPersistence` -- protocols and data model. The
  `PersistentLogEnvelope`, `PersistentLogStore`, and
  `LogRecordPersistentEncoder` surface.
- `LoggerFilePersistence` -- file-backed implementation. The planned
  `FileLogStore` actor and `Configuration` for append-only NDJSON
  persistence.

## Installation

The package manifest is not part of this spec-only PR. SwiftPM
installation instructions will land with the implementation PR that adds
`Package.swift` and the source targets.

## Planned usage model

The intended write pipeline is:

```
Logger adapter -> LogRecordPersistentEncoder -> PersistentLogEnvelope -> FileLogStore
```

`LogRecordPersistentEncoder` redacts the message and attributes and
produces an envelope.
The planned `FileLogStore` accepts envelopes through the
`PersistentLogStore` protocol and writes them as NDJSON. The M3.3.0
target exposes append-only writes.

> **Important:** Recoverable visibility, not raw file size, defines
> durable append success; canonical bytes define replay identity.

The M3.3.0 target is intentionally unbounded: rotation, retention, and
export are deferred.

## Documentation

- [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md) -- normative
  file-format, deterministic encoding, recoverable-prefix, parser
  parity, durability, byte-stable export, and corruption corpus contract.
  It is the normative source for persistence semantics and outranks
  `APIDesign.md` for those rules, including replay/export
  compatibility.
- [`Docs/CorpusSpec.md`](Docs/CorpusSpec.md) -- future detailed
  fixture plan for the conformance corpus.
- [`Docs/APICompatibility.md`](Docs/APICompatibility.md) --
  public diagnostic evolution policy.
- [`Docs/APIDesign.md`](Docs/APIDesign.md) -- API design draft, with
  the M3.3.0 surface and the future shape clearly separated; it is
  intentionally non-normative for wire-format semantics.
- [`Docs/Architecture.md`](Docs/Architecture.md) -- non-normative
  design overview (scope, non-goals, layering, logical view, failure
  model). `Architecture.md` is non-normative.
- [`Docs/FutureExportDesign.md`](Docs/FutureExportDesign.md) --
  non-contract export/remove design notes.
- [`Docs/TestingGuidance.md`](Docs/TestingGuidance.md) --
  non-normative guidance for stable diagnostics assertions.
- [`Docs/Requirements.md`](Docs/Requirements.md) -- LGP-1 ... LGP-39
  requirements catalog with milestone status.
- [`Docs/Decisions/`](Docs/Decisions) -- five ADRs (package split,
  envelope storage, file format, ordering, failure model).

## Related

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core ecosystem package providing the `Loggers` product.
