/// A durable store that accepts ``PersistentLogEnvelope`` values and
/// persists them.
///
/// The store does not encode, redact, or assign sequences.
///
/// ## Sequence contract
///
/// ``PersistentLogEnvelope/sequence`` is producer-owned metadata.
/// The store preserves it as provided and does not assign sequences
/// itself. Monotonic sequence ordering is the producer's contract.
///
/// Accepted ordering and durable admission are defined by each
/// concrete store implementation and its persistence contract.
///
/// ## Failure model
///
/// ``append(_:)`` and ``flush()`` surface I/O errors.
public protocol PersistentLogStore: Sendable {
    /// Submits an envelope for durable store admission.
    ///
    /// - Parameter envelope: The envelope to persist. The store
    ///   preserves ``PersistentLogEnvelope/sequence`` as provided.
    /// - Throws: An I/O error if the underlying medium rejects the write.
    func append(_ envelope: PersistentLogEnvelope) async throws

    /// Best-effort local synchronization boundary for buffered writes.
    ///
    /// The protocol does not define a universal durability guarantee.
    /// The exact synchronization strength is defined by each conformer.
    ///
    /// - Throws: An I/O error if the conformer cannot complete its
    ///   synchronization boundary.
    func flush() async throws
}
