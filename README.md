# swift-logger-persistence

Local persistence primitives for [`swift-loggers`](https://github.com/swift-loggers):
an adapter-agnostic envelope/store API surface plus a file-backed
implementation.

SwiftPM manifest, platform minima, and the `LoggerPersistence` core
target ship with this repository. MIT licensed.
Security reporting and supported release-line policy live in
[`SECURITY.md`](SECURITY.md).

The `0.1.x` release line covers append/flush persistence, size-based
rotation, byte-stable export, destructive removal of the exported prefix,
and count-, byte-, and age-based retention. Replay/query APIs remain
deferred.

## Products

The package shape exposes two products:

- `LoggerPersistence` -- protocols and data model. The product
  exposes `PersistentLogEnvelope`, `PersistentLogStore`, and
  `LogRecordPersistentEncoder`. Canonical envelope encoding is
  implemented by package-owned encoders, is intentionally not
  customizable by conformers, and is governed by
  [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md); it is not part
  of the public API surface.
- `LoggerFilePersistence` -- file-backed `FileLogStore`,
  configuration, size-based rotation, byte-stable export for
  parser-profile-accepted recoverable data, destructive removal for
  exported data covered by accepted-prefix recovery rules, and
  count-, byte-, and age-based retention. Removal is caller-invoked
  and performs no autonomous background maintenance.

## Installation

> **Requires Swift 6 toolchain** (the package manifest is
> `swift-tools-version: 6.0` and the public API uses typed throws).

Use the `0.1.x` patch line. The package is still pre-1.0, so the
recommended requirement is up-to-next-minor instead of SwiftPM's
default up-to-next-major `from:` shorthand:

```text
.package(
    url: "https://github.com/swift-loggers/swift-logger-persistence.git",
    .upToNextMinor(from: "0.1.0")
)
```

Add `LoggerPersistence` to targets that consume the envelope / store /
encoder surface:

```text
.product(name: "LoggerPersistence", package: "swift-logger-persistence")
```

Targets that need the file-backed store add `LoggerFilePersistence`:

```text
.product(name: "LoggerFilePersistence", package: "swift-logger-persistence")
```

Example target dependency list:

```text
.target(
    name: "AppLogging",
    dependencies: [
        .product(name: "LoggerPersistence", package: "swift-logger-persistence"),
        .product(name: "LoggerFilePersistence", package: "swift-logger-persistence")
    ]
)
```

The package declares a SwiftPM dependency on
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
for the `Loggers.LogRecord` shape; SwiftPM resolves it transitively
through this package, so consumers do not install it separately.
Platform minima follow the file-backed API surface (iOS 13.4 /
tvOS 13.4 / macOS 10.15.4 / watchOS 6.2 / visionOS 1).

## Usage model

The write pipeline is:

```
Logger adapter -> LogRecordPersistentEncoder -> PersistentLogEnvelope -> FileLogStore
```

`LogRecordPersistentEncoder` applies privacy redaction to message
privacy segments and attribute values before envelope persistence,
then produces an envelope. Record `domain`, attribute keys, and object
keys are schema and key material, are not redacted by the package, and
are persisted verbatim; callers must keep those names non-sensitive
and PII-free.
`FileLogStore` accepts envelopes through the
`PersistentLogStore` protocol and writes LF-terminated NDJSON lines
under recoverable visibility semantics defined in
[`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md). The `0.1.x`
release line exposes write-only append/flush lifecycle APIs together
with byte-stable export, destructive removal of the exported prefix,
size-based rotation, and count-, byte-, and age-based retention;
query and replay APIs remain deferred.

README terminology uses `recoverable visibility semantics` for the
persistence contract, `accepted-prefix recovery rules` for the
FileFormatSpec recovery subset, and `parser-profile-accepted
recoverable data` for recoverable data accepted by the parser profile
and eligible for byte-stable export and replay; the parser profile is
defined by
[`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md).

> **Important:** The [file-format contract](Docs/FileFormatSpec.md), not
> raw file size, is the source of recoverable visibility semantics.
> [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md) also defines parser-profile acceptance for
> recoverable data. For parser-profile-accepted recoverable data,
> parser-profile acceptance, canonical bytes, and accepted ordering
> together define replay identity. This replay-identity invariant
> governs byte-stable export and replay behavior.

The original M3.3.0 append/flush milestone scope did not impose
retention or rotation limits. M3.3.1 adds size-based rotation. M3.3.2
adds byte-stable export for parser-profile-accepted recoverable data,
destructive removal, and count-, byte-, and age-based retention. Retention
enforcement is a synchronous destructive lifecycle operation
triggered inline by append operations; it can unlink retained rotated
segments within the caller append path. It is not a background worker
or service and performs no autonomous maintenance between append calls.
Age-based retention is shipped for whole rotated segments and uses the
filesystem modification time (`mtime`) of the segment file as its
source of truth; it does not parse envelope payloads or accepted-line
timestamps.

`FileLogStore` is a local persistence layer, not a complete audit-log
platform. Regulated deployments that require additional
application-managed encryption-at-rest, externally implemented
tamper-evident record chains (for example hash chaining or signed
append manifests), remote or SIEM shipping, or operating-system
file-access enforcement must implement those layers outside this
package.

Minimal file-store setup:

```swift
import Foundation
import LoggerFilePersistence
import LoggerPersistence

let directory = URL(fileURLWithPath: "/var/tmp/app-logs", isDirectory: true)
let store = FileLogStore(configuration: .init(directory: directory))

let envelope = try PersistentLogEnvelope(
    id: UUID(),
    sequence: 1,
    createdAt: Date(),
    contentType: "application/vnd.example.log+json",
    hints: [:],
    payload: Data(#"{"message":"hello"}"#.utf8)
)

try await store.append(envelope)
try await store.flush()
```

When creating envelopes directly, the producer owns monotonic
sequence assignment. `FileLogStore` preserves caller-provided
sequence metadata and does not assign, reorder, or deduplicate it.

Rotation and retention:

```swift
import Foundation
import LoggerFilePersistence

let directory = URL(fileURLWithPath: "/var/tmp/app-logs", isDirectory: true)
let rotation = try RotationPolicy.bySize(maxSegmentBytes: 4 * 1024 * 1024)
let retention = try RetentionPolicy.maxSegments(8)

let store = FileLogStore(
    configuration: .init(
        directory: directory,
        rotation: rotation,
        retention: retention
    )
)
```

Byte-stable export and destructive removal:

```swift
import Foundation
import LoggerFilePersistence

let directory = URL(fileURLWithPath: "/var/tmp/app-logs", isDirectory: true)
let store = FileLogStore(configuration: .init(directory: directory))
let exportURL = directory.appendingPathComponent("export.ndjson")

try await store.exportLogs(to: exportURL)
try await store.removeExportedLogs()
```

`removeExportedLogs()` removes only the exported prefix captured by a
successful `exportLogs(to:)`; bytes accepted after the export
destination commit are preserved.

## Documentation

- [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md) -- normative
  file-format, deterministic encoding, recoverable visibility
  semantics including accepted-prefix recovery rules, parser-profile
  governance rules, byte-stable export for parser-profile-accepted
  recoverable data, and corruption conformance corpus contract.
  It is the normative source for persistence semantics and outranks
  [`Docs/APIDesign.md`](Docs/APIDesign.md) for those rules, including
  byte-stable replay and export compatibility.
- [`Docs/CorpusSpec.md`](Docs/CorpusSpec.md) -- detailed
  fixture plan for the conformance corpus.
- [`Docs/APICompatibility.md`](Docs/APICompatibility.md) --
  public diagnostic evolution policy for public persistence diagnostics.
  It also owns API and source compatibility guarantees across package
  releases, with source-compatible additive enum-case evolution
  guarantees only where explicitly documented; diagnostic enums remain
  non-exhaustive by explicit contract unless marked `@frozen`.
- [`Docs/APIDesign.md`](Docs/APIDesign.md) -- API design for the
  shipped `0.1.x` surface, including file-store export/remove
  surfaces and count-, byte-, and age-based retention; it is intentionally
  non-normative for wire-format and persistence semantics defined
  by [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md), which
  remains the normative source.
- [`Docs/Architecture.md`](Docs/Architecture.md) -- non-normative
  design overview (scope, non-goals, layering, logical view, failure
  model).
- [`Docs/ExportAndRemoveDesign.md`](Docs/ExportAndRemoveDesign.md) --
  implementation-oriented non-normative export/remove guidance for the
  current implementation. This document does not override
  [`Docs/FileFormatSpec.md`](Docs/FileFormatSpec.md) or
  [`Docs/APIDesign.md`](Docs/APIDesign.md) for the current milestone
  series.
- [`Docs/TestingGuidance.md`](Docs/TestingGuidance.md) --
  non-normative guidance for version-stable diagnostic assertions in
  tests.
- [`Docs/Requirements.md`](Docs/Requirements.md) -- LGP-1 ... LGP-39
  requirements catalog with milestone-tracking status.
- [`Docs/Decisions/`](Docs/Decisions) -- ADRs for package split,
  envelope storage, file format, ordering, and failure-model evolution.

## Related

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core logging package providing the `Loggers` product
  used transitively by `LoggerPersistence`.
