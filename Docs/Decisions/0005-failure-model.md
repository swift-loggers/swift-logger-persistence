# 0005 -- Failure model

Status: Accepted (M3.3.0).

## Decision

`PersistentLogStore.append(_:)` and `PersistentLogStore.flush()` are
`async throws`. Implementations surface I/O errors directly to the
caller. Logger-facing adapters that wrap a store are responsible for
catching those errors and routing them through their own diagnostics
channel, because `Loggers.Logger.log` is infallible by contract and
must not throw out of an adapter.

## Why

The persistence layer has two distinct kinds of consumers:

- **Non-logger consumers** -- export tooling, the M3.4 remote-delivery
  queue, support-bundle exporters, integration tests. These callers
  need to know when an `append` or `flush` failed so they can reroute
  the data, surface the error to the user, escalate into a retry
  state machine, or fail the test. A swallowing `Bool`-returning API
  hides the failure cause, the failure category (transient vs.
  permanent), and the underlying `errno`-equivalent.
- **Logger-facing adapters** -- the future M6 standalone file logger
  and any other logger that persists records. These callers cannot
  let an error escape `Logger.log`, because `log` is non-throwing by
  contract. They are expected to translate persistence failures into
  diagnostic events on their own channel (e.g. an `os_log` line at
  `.error` plus a counter), which is an adapter-specific concern.

Forcing the persistence layer to swallow errors so logger adapters do
not have to handle them would degrade the API for the non-logger
consumers, who are the larger surface area. Letting errors propagate
keeps both groups well served: storage callers get errors, adapters
catch them.

## Consequences

- M3.3.0 does not ship a logger-facing adapter. The discipline above
  is documented for M6 and any other future adapter; it is not
  enforced at the type level.
- The protocol stays untyped (`async throws`). This preserves
  `any PersistentLogStore` as a usable existential for code paths
  that hold a heterogeneous store (file, in-memory, SQLite, the
  future M3.4 remote queue) without forcing them through a shared
  error supertype.
- Concrete implementations narrow the contract via Swift 6 typed
  throws. `FileLogStore.append(_:)` and `FileLogStore.flush()`
  declare `throws(FileLogStoreError)`, which satisfies the
  protocol's untyped `throws` because typed throws are narrower than
  `any Error`.
- `FileLogStoreError` is a value-typed enum -- it does not wrap a
  raw `any Error`. The `.operationFailed` case carries
  `FileLogStoreOperation` (the failing pipeline step),
  the `URL` the operation was acting on, and a
  `FileSystemErrorContext` value (domain, code, localized
  description). Tests assert the exact failing operation rather
  than only the presence of an error.
- Consumers (the M3.4 remote-delivery engine, export tooling) can
  pattern-match on `FileLogStoreError.operationFailed.operation` to
  classify failures into transient / permanent / fatal categories
  without re-deriving them from the underlying error chain.

## Alternatives considered

- **`Bool`-returning API, errors via diagnostics callback.** Rejected:
  loses the underlying error cause, forces every non-logger consumer
  to subscribe to an out-of-band channel to learn whether their last
  call succeeded, and complicates testing.
- **`Result<Void, Error>` returning API.** Rejected in favor of
  Swift 6 typed throws on the concrete impl: `Result` would be a
  wrapper most callers immediately unwrap with `try`, and we get the
  same compile-time exhaustiveness from `throws(FileLogStoreError)`.
- **Typed throws on the protocol** (`PersistentLogStore.append`
  returning `throws(some Error)` or with an `associatedtype StoreError`).
  Rejected: kills the existential `any PersistentLogStore` use cases
  the package is intentionally enabling -- the M3.4 remote queue
  holds a `PersistentLogStore` reference whose concrete type it does
  not care about, and an associated type or generic throw forces
  every such call site through generic plumbing.
- **`case ioError(underlying: any Error)` inside `FileLogStoreError`.**
  Rejected: putting `any Error` in a public enum case erases the
  point of typed throws, breaks `Equatable`, and weakens the
  `Sendable` story when the wrapped error happens to retain
  non-`Sendable` references. The value-typed
  `FileSystemErrorContext` projection captures everything callers
  need (domain, code, description) without dragging the original
  error reference across boundaries.
