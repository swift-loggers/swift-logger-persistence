# swift-logger-persistence

Local durable persistence primitives for [`swift-loggers`](https://github.com/swift-loggers):
an adapter-agnostic envelope/store contract plus a file-backed
implementation.

SwiftPM manifest, platform minima, and the `LoggerPersistence` core
target ship with this repository. MIT licensed.

> **API in active design.** This pre-1.0 package is not tagged yet.

## Products

The currently shipped package shape exposes two products:

- `LoggerPersistence` -- protocols and data model. The product
  exposes `PersistentLogEnvelope`, `PersistentLogStore`, and
  `LogRecordPersistentEncoder`. Canonical envelope encoding is
  implemented by package-owned encoders and governed by
  [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md); it is not part
  of the public API surface.
- `LoggerFilePersistence` -- file-backed `FileLogStore`,
  configuration, byte-stable export, and destructive removal
  lifecycle.

## Installation

> **Requires Swift 6 toolchain** (the package manifest is
> `swift-tools-version: 6.0` and the public API uses typed throws).

> **Pre-tag.** This repository has no released SemVer tag yet, so a
> `from:` (or `.upToNextMinor(from:)`) requirement has nothing to
> resolve against. Until the first tag lands, depend on the branch
> or a specific revision.

Pre-tag (current), pinned to a development branch:

```swift
.package(
    url: "https://github.com/swift-loggers/swift-logger-persistence",
    branch: "main"
)
```

or pinned to a specific commit:

```swift
.package(
    url: "https://github.com/swift-loggers/swift-logger-persistence",
    revision: "<commit-sha>"
)
```

After the first tag lands, switch to the released SemVer
requirement and replace the placeholder below with the actual
released tag (plain SemVer, no leading `v`):

```swift
// after the first release tag, replace `<first-release-version>`
// with the actual tag (plain SemVer, no leading `v`):
.package(
    url: "https://github.com/swift-loggers/swift-logger-persistence",
    from: "<first-release-version>"
)
```

Then add the `LoggerPersistence` product to the targets that consume
the envelope / store / encoder surface:

```swift
.product(name: "LoggerPersistence", package: "swift-logger-persistence")
```

Targets that need the file-backed store add `LoggerFilePersistence`:

```swift
.product(name: "LoggerFilePersistence", package: "swift-logger-persistence")
```

The package depends on
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
for the `Loggers.LogRecord` shape. Platform minima follow the
file-backed API surface (iOS 13.4 / tvOS 13.4 / macOS 10.15.4 / watchOS 6.2 /
visionOS 1) so the manifest stays compatible across the milestone PR
sequence.

## Usage model

The intended write pipeline is:

```
Logger adapter -> LogRecordPersistentEncoder -> PersistentLogEnvelope -> FileLogStore
```

`LogRecordPersistentEncoder` redacts the message and attributes and
produces an envelope.
`FileLogStore` accepts envelopes through the
`PersistentLogStore` protocol and writes LF-terminated NDJSON
accepted lines. The M3.3.0 target exposes append/flush-only
persistence APIs.

> **Important:** Recoverable visibility, not raw file size, defines
> durable append success; canonical bytes and accepted ordering define
> replay identity.

The original M3.3.0 append/flush target was intentionally unbounded.
M3.3.1 adds size-based rotation. M3.3.2 adds byte-stable export,
destructive removal, and count/byte retention. Age-based retention
remains deferred.

## Documentation

- [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md) -- normative
  file-format, deterministic encoding, recoverable-prefix, approved
  parser-profile governance, durability, byte-stable export, and
  corruption corpus contract.
  It is the normative source for persistence semantics and outranks
  `APIDesign.md` for those rules, including replay/export
  compatibility.
- [`Docs/CorpusSpec.md`](Docs/CorpusSpec.md) -- detailed
  fixture plan for the conformance corpus.
- [`Docs/APICompatibility.md`](Docs/APICompatibility.md) --
  public diagnostic evolution policy.
- [`Docs/APIDesign.md`](Docs/APIDesign.md) -- API design draft,
  including current file-store export/remove surfaces and current
  count/byte retention shape (age-based retention deferred); it is
  intentionally non-normative for wire-format semantics.
- [`Docs/Architecture.md`](Docs/Architecture.md) -- non-normative
  design overview (scope, non-goals, layering, logical view, failure
  model).
- [`Docs/ExportAndRemoveDesign.md`](Docs/ExportAndRemoveDesign.md) --
  non-normative export/remove design notes.
- [`Docs/TestingGuidance.md`](Docs/TestingGuidance.md) --
  non-normative guidance for stable diagnostics assertions.
- [`Docs/Requirements.md`](Docs/Requirements.md) -- LGP-1 … LGP-39
  requirements catalog with milestone status.
- [`Docs/Decisions/`](Docs/Decisions) -- five ADRs (package split,
  envelope storage, file format, ordering, failure model).

## Related

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core ecosystem package providing the `Loggers` product.
