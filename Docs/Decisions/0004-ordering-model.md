# 0004 -- Ordering model

Status: Accepted (M3.3.0).

## Decision

`PersistentLogEnvelope.sequence` is monotonic and producer-assigned,
synchronously, before any `async` boundary. The actor that fronts a
file-backed `PersistentLogStore` is I/O serialization, not the
sequence source: it preserves whatever sequence the caller already
put in the envelope.

The in-tree producer that satisfies this contract is
`LogRecordPersistentEncoder`, which owns a synchronized `UInt64`
counter and increments it inside the synchronous body of `encode(_:)`.
Each call to `encode` therefore returns an envelope whose sequence is
strictly greater than every prior return from the same encoder, even
when many tasks call `encode` concurrently.

## Why

Swift actors are reentrant: an `await` inside an actor method releases
the actor's serial executor and lets queued calls run. That means the
order in which writes complete on disk inside an `actor`-fronted store
is **not** guaranteed to match the order in which producers invoked
`append`. If sequence were assigned inside the store, two producers
calling `append` "first" and "second" could observe their work
written under sequences `2` and `1` respectively, depending on
scheduler interleavings.

Assigning sequence synchronously before the async hop fixes this.
Producers race only on the synchronous increment; once they hold their
sequence, the actor reentrancy that follows can freely reorder write
completion without changing which sequence belongs to which producer
event.

## Consequences

- The recommended path for record-based producers is
  `LogRecordPersistentEncoder`, which owns the counter.
- Producers that build envelopes themselves (the future M3.4
  remote-delivery queue, custom test fixtures) are responsible for monotonic
  sequence ordering on their side. The store's protocol comment
  documents this expectation.
- Tests assert deterministic sequence ordering across concurrent
  encodes. They do not assert deterministic write order at the file
  layer; that ordering is a property of the actor's scheduler at the
  moment of test, and the test fixture sorts observed sequences before
  asserting equality with the expected range.
- Flush observes store serialization order, not wall-clock invocation
  order. Concurrent append/flush callers must not treat invocation order
  as a persistence guarantee.

## Alternatives considered

- **Store assigns sequence inside the actor.** Rejected: cannot
  guarantee the sequence the caller sees matches the order in which
  the caller submitted, due to actor reentrancy.
- **No sequence at all; rely on file order.** Rejected: file order
  does not express producer event order and breaks under concurrent
  writer topologies. Sequence is producer ordering metadata for logical
  consumers such as the future remote-delivery queue; byte-stable export
  ordering is owned by [`../FileFormatSpec.md`](../FileFormatSpec.md),
  not this ADR.
