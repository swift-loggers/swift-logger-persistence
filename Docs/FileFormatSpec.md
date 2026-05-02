# File Format Spec

Normative wire-format and corruption contract for package-provided
file-backed stores. `APIDesign.md` owns the Swift API;
this document owns the portable on-disk profile for stores and future
replay/export implementations.

This document is the single normative source for the persistence contract;
conflicting wording elsewhere is non-authoritative. Normative keywords
(`MUST`, `MUST NOT`, `SHOULD`) are authoritative only here, and
normative examples are binding unless marked illustrative.
Compatibility is defined by observable bytes and corpus results, not
implementation strategy; observable bytes outrank implementation
internals.

## Defined Terms

- **Accepted line**: the primary persistence unit; one complete
  LF-terminated envelope line admitted into the recoverable prefix.
- **Accepted ordering**: file-format order of accepted lines in the
  recoverable prefix.
- **Accepted bytes**: exact bytes of accepted lines, including
  delimiters.
- **Canonical bytes**: byte spelling required by this profile for
  encoded envelopes and package-owned payloads.
- **Recoverable prefix**: byte prefix ending after the last complete
  accepted line.
- **Recoverable visibility**: accepted lines in the recoverable prefix.
- **Append unit**: pre-admission line candidate; after admission it is an
  accepted line.
- **Replay identity**: byte-exact identity of accepted bytes, including
  delimiters and accepted ordering.

Terminology is locked to the terms above. New invariants require:

- canonical owner section in this file
- compatibility class: wire bytes, validation, append/flush, recovery,
  diagnostics, or corpus
- exact glossary terminology

Forbidden aliases in portable docs:

- `accepted envelope bytes` -> `accepted bytes`
- `accepted line order` and `replay/export ordering` -> `accepted ordering`
- `recoverable durability` -> `recoverable visibility`
- `canonical deterministic bytes` -> `canonical bytes`
- `append unit` only before admission; after admission use `accepted line`

Other documents reference these terms instead of redefining them.

## Scope

The portable profile applies to package-provided stores and
third-party stores that claim portable compatibility. Non-portable
extensions require their own `contentType` / versioning contract and
MUST NOT claim portable compatibility.

## 1. Wire Format

### Envelope Line

Each append unit is exactly one LF-terminated JSON object.

- LF (`0x0A`) is the only delimiter in the portable profile; CRLF is
  never valid
- Escaped LF sequences inside JSON strings are data, not delimiters
- LF delimiter ownership is append-local and deterministic
- Empty lines are never valid append units
- `payload` is always base64-encoded
- mixed inline/base64 payload representations are forbidden within the
  portable profile

### Field Constraints

- `id` identifies one envelope.
- `sequence` is producer-owned metadata, independent from append
  completion order.
- `contentType` identifies payload format, not storage routing.
- `hints` are optional metadata for package filtering and indexing, with
  no ordering role.

## 2. Validation

### Identity and Ordering Fields

- `id` text MUST use canonical hyphenated RFC 4122 form with lower-case
  hexadecimal digits (`8-4-4-4-12`). Replay/export parsers MUST reject
  uppercase hex, braces, `urn:uuid:` prefixes, unhyphenated text, and
  other alternate spellings instead of canonicalizing them. This
  intentionally diverges from Foundation `UUID(uuidString:)`
  permissiveness.
- UUID validation MUST NOT delegate directly to permissive Foundation
  parsing.
- UTF-8 corruption validation precedes field validation.
- Canonical UUID spelling is a compatibility contract. Replay/export
  comparison is byte-exact and never locale-aware; invalid spelling is
  rejected before replay identity comparison.
- `sequence` valid values are `1...UInt64.max`; `0` is reserved and
  invalid. Sequence wrap must fail before emitting an envelope.
- Sequence comparison is numeric, not lexical.
- Sequence ordering is independent from filesystem append or concurrent
  execution order.

### Timestamp Field

- `createdAt` uses RFC 3339 UTC with fixed millisecond fractional
  precision, literal `Z`, POSIX locale, and the Gregorian calendar.
- Timestamp bytes, including millisecond precision, participate in
  replay identity.
- No timestamp or timezone normalization occurs.
- Leap-second text (`:60`) is validation failure.

### Text Fields

- `contentType` MUST be visible ASCII, MUST contain no whitespace or
  control characters, and MUST be 1...128 bytes when UTF-8 encoded.
  `contentType` values for JSON payloads MUST be `application/json` or
  use a structured syntax suffix (`+json`).
- UTF-8 byte length, not scalar count, defines text limits.
- `contentType` bytes participate in replay identity exactly as
  persisted. Matching is byte-exact, normalization-free, and performs no
  trimming, case folding, or Unicode equivalence checks.

### Hint Fields

Structure:

- `hints` may contain at most 16 entries. Hint keys must be 1...128
  UTF-8 bytes using only ASCII letters, digits, `.`, `_`, and `-`. Hint
  values must be valid Swift `String` values, at most 512 UTF-8 bytes,
  and must not contain ASCII control characters (`U+0000`...`U+001F`,
  `U+007F`). Control-character detection is scalar-based.

Privacy:

- Hints are optional metadata for package filtering and indexing, not
  authoritative payload. They must not contain raw private or sensitive
  data.
- Hint iteration order is ignored unless explicitly versioned and MUST
  NOT affect accepted ordering or byte-stable export.
- Hint metadata never participates in payload decoding.

### Payload and Bounds

- Payload bytes are opaque to package-provided storage code.
  Admission validation may validate byte length but MUST NOT inspect
  payload bytes.
- Accepted ordering MUST NOT depend on payload bytes.
- Compression and indexing MUST NOT depend on decoded payload values.
- Raw `payload` MUST be at most 1 MiB per envelope
  (`1_048_576 bytes`).
- The encoded NDJSON line, including base64 payload, metadata, hints,
  JSON punctuation, and trailing newline, MUST NOT exceed 2 MiB
  (`2_097_152 bytes`).
- Line-size validation uses UTF-8 bytes after canonical JSON encoding.
- Base64 spelling is a compatibility contract.
- Wrappers above persistence do not relax the payload limit: bytes handed
  to persistence must still fit the 1 MiB portable limit.

Package-provided stores MUST reject over-limit envelopes before writing
bytes for that envelope.

### String Encoding

Malformed or non-shortest UTF-8 is corruption, not repair opportunity.
UTF-8 validity is checked before field validation.

### Field Determinism

- `contentType` and hint key comparison are exact and case-sensitive.
  Stores and routers MUST NOT trim, lowercase, uppercase, or otherwise
  canonicalize `contentType`.
- Persisted text bytes must remain byte-stable across supported
  platforms without lossy conversion, replacement characters, default
  encodings, or platform transcoding.
- The persistence layer MUST NOT normalize Unicode (`NFC`, `NFD`, or any
  other form).

### Validation Admission Boundary

An envelope is not accepted into storage until validation succeeds.
Validation completes before any storage mutation for that envelope.
Before admission, package-provided stores must not write bytes or mutate
rotation state for the envelope.

Successful admission creates exactly one accepted line and extends
accepted ordering. Rejected envelopes do not affect accepted ordering,
and no accepted bytes for that envelope exist before admission.

Envelope JSON encoding failures after successful field validation are
reported as `.operationFailed(operation: .encodeEnvelope, ...)`, not
`invalidEnvelope`.

### Validation Precedence

#### Precedence

Precedence applies after successful structural extraction and before
admission.
Corruption failures precede validation precedence evaluation.
Corruption classification outranks envelope validation.
The corpus governs expected validation-precedence outcomes.

If more than one validation condition is violated, package-provided
stores use this first-failure order:

1. invalid `id`
2. invalid `sequence`
3. invalid `createdAt`
4. invalid `contentType`
5. too many hints
6. lexicographically first invalid hint key
7. lexicographically first too-long hint value
8. lexicographically first hint value containing a control character
9. raw payload too large
10. JSON encoding failure
11. encoded envelope line too large

Lexicographic ordering uses UTF-8 byte order over the original Swift
`String` contents exactly as supplied, before normalization, transcoding,
trimming, filesystem/path conversion, or any other canonicalization step.
It does not use locale comparison, case folding, or Unicode
normalization.

#### Precedence Compatibility

For identical extracted field values, validation precedence is
deterministic. Within one package major version,
package-provided stores must not change which validation case is reported
first for the same invalid envelope bytes after structural extraction.

Failures before field extraction follow the corruption corpus, not this
list.

## 3. Deterministic Encoding

Package-owned JSON payloads follow these canonical byte requirements:

- `JSONEncoder.outputFormatting = [.sortedKeys]`
- no `.prettyPrinted`
- solidus (`/`, `U+002F`) is emitted as `\/`; escaping strategy is
  a compatibility contract within the portable profile and is covered by
  the corpus
- object keys are sorted at every depth, including nested
  `LogValue.object` dictionaries and future map-shaped payload fields,
  recursively before serialization
- dictionary insertion order must never affect encoded bytes
- UUID text uses lower-case canonical RFC 4122 spelling
- non-ASCII scalar values are emitted as UTF-8 characters rather than
  normalized or force-converted to `\u` escapes
- dates use exact RFC 3339 UTC milliseconds from the timestamp profile
  above
- finite `LogValue.double` values use the package canonical binary64
  decimal profile: shortest round-tripping decimal, lowercase `e` when
  exponent form is needed, no `+` exponent sign, no unnecessary leading
  exponent zeros, and no trailing fractional zeros
- non-finite floating-point values are invalid in the portable JSON
  payload profile
- encoded bytes must not depend on caller locale, calendar, time-zone, date
  formatter state, CPU architecture, or Swift `Dictionary` iteration
  order, and must remain stable across supported architectures and
  package patch releases unless a new `contentType` / version is
  declared

Object key ordering is defined recursively at every object depth by
comparing the UTF-8 byte sequences of the exact key strings before JSON
escaping. The comparison uses no Unicode normalization, locale, case
folding, scalar-equivalence checks, or dictionary insertion order. The
comparator applies before JSON string serialization.

If a future Foundation release changes encoded bytes for this profile,
the package must shim or replace that encoder to preserve byte stability, or
publish a new `contentType` / declared compatibility break.

### Payload Format Versioning

Package-owned payload formats are versioned by `contentType`, not by an
implicit decoder switch. JSON payload formats use the structured syntax
suffix form; the redacted `LogRecord` payload uses
`application/vnd.swift-logger.record-redacted.v1+json`.

Package-owned `contentType` versions are append-only and reserved to
this package within one package major version. Unknown future versions
are opaque, not invalid. Future replay/export implementations must
preserve accepted bytes and accepted ordering for those envelopes. Unknown
versions are never auto-upgraded or treated as known versions.

In that payload, private and sensitive attribute values become
`LogValue.string("<private>")` and `LogValue.string("<redacted>")`.

Payload shape changes require a new package-owned `contentType` version
or a declared compatibility break.

## 4. Append/Flush

### Append Contract

`append(_:)` encodes one envelope into one NDJSON append unit.
A successful append admits exactly one accepted line.

Package-provided file stores validate envelope metadata, raw payload, and
encoded line size before admission. Partial lines never become
recoverable.

### Append Rotation Interaction

Future rotation or multi-segment layouts preserve append cardinality.
LF delimiter ownership remains append-local across rotation.
Rotation must preserve the append being processed as one accepted line:
it must not split one envelope across segments, duplicate it as multiple
recoverable lines, or make append success depend on reading multiple
segments.
Rotation boundaries do not affect accepted bytes or accepted ordering.

### Append Failure Model

Failed or interrupted appends are interpreted through the
recoverable-prefix contract below.

- Bytes beyond the recoverable prefix are not replay/export input under
  any parser profile.
- They MUST NOT influence accepted ordering or replay identity and are
  never canonicalized.

### Flush

`flush()` is a best-effort local synchronization boundary for accepted
appends; it preserves but never expands recoverable visibility.
Package-provided stores define one append/flush operation order. A flush
includes every append accepted earlier in that operation order. Caller
invocation order is not a guarantee.

### Cancellation

Cancellation has no separate acceptance outcome: the operation either
admits one accepted line or rejects, even under task cancellation races.
A cancelled task may still receive success if the operation already
completed.

### Implementation Invariant Diagnostics

Invariant cases report implementation defects. Public diagnostics are
append-only within one package major version.

#### Append

Append invariant violations describe broken append postconditions:

- `appendProducedNoRecoverableLine`: an append completed without making
  the expected envelope line part of the recoverable prefix.
- `appendProducedMultipleRecoverableLines`: one append operation made
  more than one complete line recoverable.
- `appendRewroteRecoverablePrefix`: bytes in the prior recoverable
  prefix changed during a later append.

#### Encoding

Encoding invariant violations describe broken line-shape assumptions:

- `encodedEnvelopeMissingTrailingLF`: the encoded line has no final LF.
- `encodedEnvelopeContainsInteriorLF`: the encoded line contains an LF
  before its final LF.

Wire-format shape violations are invariant failures.

#### Corruption

Corruption invariant violations describe broken corruption
postconditions:

- `corruptEnvelopeAccepted`: a corrupt envelope was reported as valid.
- `corruptionClassificationMismatch`: the corpus-defined corruption class
  was not preserved.

Corruption diagnostics follow corpus classifications and never downgrade
hard-stop outcomes. Size failures remain validation failures.

## 5. Corruption/Recovery

### Recoverable File Prefix

For segment recovery, the recoverable prefix is the maximal byte prefix
that ends immediately after a complete LF-terminated NDJSON envelope
line and contains no corrupted interior line.

Recoverable prefix discovery MUST start at byte 0. Discovery is
deterministic for identical bytes and monotonic for a successfully
processed segment. Discovery must not reorder accepted lines.

Recovery may discard bytes after the recoverable prefix; recoverable
visibility and accepted ordering remain unchanged. Trailing partial
bytes are never parsed as an envelope. A complete LF-terminated line is
necessary but not sufficient for validity.

A LF-terminated line that contains malformed UTF-8, malformed JSON, a
non-object JSON value, duplicate JSON object member names, malformed
base64, or a JSON object that is not a valid envelope is interior
corruption, not a partial tail. Replay/export implementations must fail
at the interior-corruption boundary. They must not truncate at the
previous LF and silently discard already acknowledged lines after the
corrupted one.

Corruption classification outranks recovery heuristics.
Prefix discovery never skips corrupted interior lines.
Interior corruption is never downgraded to trailing truncation.

For APIs that expose whole-operation success or failure, interior
corruption is a hard stop: the operation must throw or return a typed
corruption result and must not report success with partial progress. A
future partial-recovery mode must be named explicitly and must return the
accepted prefix and corruption boundary as structured data.

### Byte-Stable Export

Export MUST preserve accepted ordering independent of filesystem
enumeration order or segment naming, and reproduce selected accepted
bytes exactly. It must not synthesize new canonical bytes or decode and
re-encode a decoded-equivalent envelope.
Export never rewrites LF delimiter ownership.

### Logical Export

A separate logical export API may decode and normalize. Logical export
intentionally breaks byte identity and must declare its schema before it
lands.

### Duplicate JSON Object Members

Duplicate JSON object member names are rejected: no first-wins or
last-wins outcome is portable. This applies to the outer envelope
JSON object and to package-owned JSON payloads when those payloads are
decoded by package APIs. Foundation parsers must not be assumed to reject
duplicate member names automatically; package decode, replay, and export
code must use explicit duplicate-member detection or a parser mode proven
by the conformance corpus.

Duplicate detection is recursive at every object depth and precedes
field handling.
Duplicate rejection is deterministic across approved parser profiles.
Duplicate-member handling never uses parser-native first/last-wins
outcomes.

## 6. Corpus Governance

The package conformance corpus defines corruption detection. Approved
profiles must match corpus results for accepted bytes, rejected bytes,
classification, and recovery boundary.

The corpus is owned by the `swift-logger-persistence` maintainers.
Fixtures and expected results are normative, an append-only compatibility
contract within one major version. New fixtures may be added for newly
specified corruption classes, but additions require PR review. A fixture
that creates a new corruption class, changes a compatibility contract, or
changes an existing expected result requires an ADR or ADR update.

Once released, corpus fixture bytes are immutable canonical test vectors
within one package major version. Fixture ordering is meaningful only
when it explicitly tests ordering.

Approved profiles include Darwin Foundation. Additional parser profiles
require explicit platform support and corpus approval.
Parser replacement is compatible only when corpus outcomes are preserved
exactly:

- byte fixtures remain byte-identical, including delimiter bytes
- accepted bytes and accepted ordering match
- corruption classification and corruption boundaries match
- recovery boundaries and recovery outcomes match

Corpus outcomes, not implementation-native parser results, govern
portable compatibility.
Changing corpus-defined corruption classes is compatibility-breaking.

### Minimum Corpus Coverage

Before replay/export lands, the corpus must cover at least these fixture
categories:

- UTF-8 corruption
- JSON corruption
- delimiter corruption
- duplicate-key corruption
- float canonicalization
- base64 corruption
- mixed recovery
- canonical key-ordering fixtures

Detailed fixture candidates live in `CorpusSpec.md`.

## Operational Notes

Single-segment filenames are outside this portable format contract.
Segment naming, rotation boundaries, and retention are separate policy
contracts.
