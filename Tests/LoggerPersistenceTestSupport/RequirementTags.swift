import Testing

/// Swift Testing tags for `Docs/Requirements.md` requirement IDs.
///
/// One tag per LGP ID; tags without test references are retained
/// so the catalog stays 1:1 with the spec.
extension Tag {
    // MARK: Core API

    /// Stores preserve caller-provided producer sequence.
    @Tag public static var lgp1: Self
    /// Store APIs expose I/O errors with `throws`.
    @Tag public static var lgp2: Self
    /// Adapters do not throw from `log`; diagnostics report failures.
    @Tag public static var lgp3: Self
    /// Default `LogRecord` persistence redacts before writing.
    @Tag public static var lgp4: Self

    // MARK: File Store Lifecycle

    /// File store exposes `flush`.
    @Tag public static var lgp5: Self
    /// File store rotates by size.
    @Tag public static var lgp6: Self
    /// File store enforces retention.
    @Tag public static var lgp7: Self
    /// File store exports retained data byte-stably.
    @Tag public static var lgp8: Self
    /// File store removes retained entries.
    @Tag public static var lgp9: Self

    // MARK: Recoverable Visibility

    /// Recoverable visibility is the durability boundary.
    @Tag public static var lgp10: Self
    /// Successful admission extends accepted ordering.
    @Tag public static var lgp11: Self
    /// Flush contract is defined by the file-format specification.
    @Tag public static var lgp12: Self
    /// Rejected envelopes never mutate recoverable visibility.
    @Tag public static var lgp13: Self
    /// Bytes beyond the recoverable prefix are non-authoritative
    /// for replay/export.
    @Tag public static var lgp14: Self
    /// Undefined suffix bytes never enter recoverable visibility.
    @Tag public static var lgp15: Self
    /// Only trailing final-line truncation is recoverable.
    @Tag public static var lgp16: Self
    /// Interior corruption is a hard-stop.
    @Tag public static var lgp17: Self
    /// Recovery discovery starts at byte zero.
    @Tag public static var lgp18: Self
    /// Cancellation creates no accepted bytes or accepted-ordering
    /// changes.
    @Tag public static var lgp19: Self

    // MARK: Canonical Bytes And Validation

    /// Canonical key ordering is recursive and insertion-order
    /// independent.
    @Tag public static var lgp20: Self
    /// The package owns canonical bytes.
    @Tag public static var lgp21: Self
    /// Line-size validation uses UTF-8 byte size.
    @Tag public static var lgp22: Self
    /// Persistence performs no Unicode normalization.
    @Tag public static var lgp23: Self
    /// Rejected envelopes do not mutate storage.
    @Tag public static var lgp24: Self
    /// Admission is the storage mutation boundary.
    @Tag public static var lgp25: Self
    /// LF delimiter ownership is append-local.
    @Tag public static var lgp26: Self
    /// Accepted bytes, including delimiters, are preserved
    /// byte-for-byte.
    @Tag public static var lgp27: Self
    /// Payload opacity is defined by the file-format specification.
    @Tag public static var lgp28: Self
    /// Canonical UUID spelling is a compatibility contract.
    @Tag public static var lgp29: Self

    // MARK: Replay, Export, And Parser Governance - Content-Type Compatibility

    /// Unknown `contentType` versions stay opaque.
    @Tag public static var lgp30: Self

    // MARK: Replay, Export, And Parser Governance - Replay And Export Identity

    /// Replay identity is defined by the file-format specification.
    @Tag public static var lgp31: Self
    /// Byte-stable export is defined by the file-format specification.
    @Tag public static var lgp32: Self

    // MARK: Replay, Export, And Parser Governance - Parser Governance

    /// Approved parser profiles produce corpus-equivalent results.
    @Tag public static var lgp33: Self
    /// Corpus defines duplicate-member rejection.
    @Tag public static var lgp34: Self

    // MARK: Replay, Export, And Parser Governance - Corruption Governance

    /// Corpus defines corruption classifications.
    @Tag public static var lgp35: Self
    /// Corpus defines recovery boundaries.
    @Tag public static var lgp36: Self
    /// Corpus defines hard-stop outcomes.
    @Tag public static var lgp37: Self

    // MARK: Replay, Export, And Parser Governance - Validation Governance

    /// Validation precedence is a compatibility contract.
    @Tag public static var lgp38: Self

    // MARK: Deferred Policy

    /// Rotation preserves append cardinality and is not
    /// replay-visible.
    @Tag public static var lgp39: Self
}
