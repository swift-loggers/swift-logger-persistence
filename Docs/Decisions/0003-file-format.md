# 0003 -- File format

Status: Accepted (M3.3.0).

## Decision

`FileLogStore` writes envelopes as append-only NDJSON: one envelope per
LF-terminated JSON object. `payload` is **always** base64-encoded. Mixed
inline/base64 payload representations are not permitted in v1, even when
the payload is itself JSON.

## Why

- **Append safety.** NDJSON is append-only by construction. One
  LF-terminated line per envelope keeps the file backend simple and
  inspectable without requiring a trailer or global file manifest.
- **Crash recovery.** A truncated final line is recoverable without a
  trailer or footer, and append inspectability survives partial
  truncation.
- **Payload shape.** Always-base64 avoids a second inline-JSON payload
  representation, removes parser ambiguity, and keeps one portable
  payload spelling across portable tooling without payload-shape
  negotiation.
- **Debuggability.** A developer can `cat` a segment, pick a line,
  and decode it manually with standard tooling. The structure is
  legible during corruption investigation without project-specific
  tooling or parsers, and NDJSON preserves append inspectability with
  standard tooling.

## Alternatives considered

- **Length-prefixed binary frames.** Tighter on disk and avoids the
  base64 tax, but has weaker human inspectability, loses the
  `cat`/`tail`/`grep` debuggability that NDJSON gives essentially for
  free, and weakens recoverable-prefix inspectability. Reconsidered if
  profiling at scale shows the base64 path is meaningfully expensive;
  not required for M3.3.x.
- **SQLite-backed store.** Acknowledged as a future option; the
  package split (see [`0001-package-split.md`](0001-package-split.md)) keeps it possible
  without locking the public API to a file format. Portable
  interchange would become engine-defined. Out of scope for M3.3.x.
- **Mixed inline/base64 payload representations.** Rejected explicitly:
  removes a class of producer/consumer mismatches at the cost of the
  base64 size overhead. Not worth the ambiguity even though some
  payloads happen to be JSON.

## Notes

Normative contract and compatibility authority live in
[`../FileFormatSpec.md`](../FileFormatSpec.md); ADR wording is
rationale-only.
