# 0001 -- Package and product split

Status: Accepted (M3.3.0).

## Decision

The target `swift-logger-persistence` package shape has two products:

- **`LoggerPersistence`** -- protocols and data model
  (`PersistentLogEnvelope`, `PersistentLogStore`,
  `LogRecordPersistentEncoder`). Depends on `Loggers` from
  `swift-logger`.
- **`LoggerFilePersistence`** -- file-backed implementation
  (`FileLogStore`, `FileLogStore.Configuration`). Depends on
  `LoggerPersistence` only.

The two layers stay in one Swift package so they version together, but
they are distinct products so a consumer that does not use the file
backend can import only `LoggerPersistence`.

## Why

A future in-memory or SQLite-backed implementation needs the
envelope and store contract without inheriting the file backend's
surface. Forcing the file implementation into the same target as the
protocols would couple every conforming store to `Foundation`'s
`FileHandle` / `FileManager` symbols, and would force consumers
(remote-delivery queue, in-memory test doubles) to link the file
backend even when they never write a byte to disk.

## Alternatives considered

- **Single product carrying everything.** Rejected: forces every
  conforming store to ship alongside the file backend, even where
  the file backend is unused. Couples non-file consumers to file I/O
  symbols and makes it harder to reason about platform availability.
- **Three products** (`LoggerPersistence`, `LoggerRecordPersistence`
  for the encoder, `LoggerFilePersistence`). Rejected as premature:
  the encoder is small, lives naturally with the protocols, and
  splitting it adds module-boundary cost without a consumer-driven
  reason. If a future consumer needs the protocols without the encoder,
  the encoder can move to its own target then.
