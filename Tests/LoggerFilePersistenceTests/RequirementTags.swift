import Testing

/// Shared LGP requirement tags referenced by Swift Testing suites.
extension Tag {
    /// Stores preserve caller-provided producer sequence.
    @Tag static var lgp1: Self
    /// Store APIs expose I/O errors with `throws`.
    @Tag static var lgp2: Self
    /// File store exposes `flush`.
    @Tag static var lgp5: Self
    /// File store rotates by size.
    @Tag static var lgp6: Self
    /// Successful admission extends accepted ordering.
    @Tag static var lgp11: Self
    /// Flush contract follows `FileFormatSpec.md`.
    @Tag static var lgp12: Self
    /// Rejected envelopes never mutate recoverable visibility.
    @Tag static var lgp13: Self
    /// Bytes beyond the recoverable prefix are non-authoritative
    /// for replay/export.
    @Tag static var lgp14: Self
    /// Undefined suffix bytes never enter recoverable visibility.
    @Tag static var lgp15: Self
    /// The package owns canonical bytes.
    @Tag static var lgp21: Self
    /// Line-size validation uses UTF-8 byte size.
    @Tag static var lgp22: Self
    /// Rejected envelopes do not mutate storage.
    @Tag static var lgp24: Self
    /// Admission is the storage mutation boundary.
    @Tag static var lgp25: Self
    /// LF delimiter ownership is append-local.
    @Tag static var lgp26: Self
    /// Accepted bytes, including delimiters, are preserved
    /// byte-for-byte.
    @Tag static var lgp27: Self
    /// Validation precedence is a compatibility contract.
    @Tag static var lgp38: Self
    /// Rotation preserves append cardinality and is not
    /// replay-visible.
    @Tag static var lgp39: Self
}
