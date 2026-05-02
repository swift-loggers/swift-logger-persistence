# 0002 -- Envelope storage and the dual layer

Status: Accepted (M3.3.0).

## Decision

`swift-logger-persistence` exposes two consumption layers over the
same `PersistentLogStore` contract:

- **Low-level envelope.** `PersistentLogEnvelope` carries an opaque
  `payload: Data`. Producers that already have a wire-format payload
  (for example a remote-delivery queue holding pre-built NDJSON
  request bodies) construct envelopes themselves and append directly.
  The store does not parse the payload.
- **Convenience encoder.** `LogRecordPersistentEncoder` bridges
  `Loggers.LogRecord` to `PersistentLogEnvelope`: it redacts the
  message and attributes, encodes a JSON projection of the redacted
  record into the payload, assigns the sequence, and stamps the
  envelope with the encoder's `contentType`.

`FileLogStore` only sees envelopes. It does not import `LogRecord` or
participate in redaction.

## Why

The two downstream consumers of this layer want different things:

- **M6 file-logger.** Wants to persist `LogRecord` directly with
  redaction applied. The encoder owns that bridge.
- **M3.4 remote-delivery queue.** Wants to enqueue ready-to-ship
  payloads (NDJSON `_bulk` bodies, Datadog Logs intake JSON, etc.)
  produced by per-vendor encoders and never re-encode at flush time.
  The opaque envelope is the right unit.

A single layer that only accepted `LogRecord` would force the remote
queue to either store records and re-encode on every flush attempt
(wasting CPU and risking encoding nondeterminism across retries), or
to introduce a parallel storage layer of its own. A single layer that
only accepted opaque `Data` would push redaction and record encoding
into every consumer that wants the record-aware path, duplicating
work and weakening the redaction guarantee.

## Notes

The encoder is expected to evolve: future versions may stamp
additional hints, support alternative content types, or expose a
`Sendable` snapshot of the sequence cursor for diagnostics. The dual
layer makes those changes additive.
