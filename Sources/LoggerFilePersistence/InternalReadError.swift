import Foundation

/// Internal failure surface for read-side discovery and scanning.
///
/// Consumed by `FileLogStore`'s reopen path and by future
/// recovery-discovery types. Public error mapping happens in the
/// public surface that wraps these helpers; this type is not part
/// of the package's public API.
internal enum InternalReadError: Error, Sendable, Equatable {
    /// A file-system step in read-side discovery or scanning failed.
    ///
    /// The associated values name the read-side pipeline step
    /// (``InternalReadOperation``), the `URL` the step was acting on,
    /// and a value-typed ``FileSystemErrorContext`` snapshot of the
    /// underlying error.
    case operationFailed(
        operation: InternalReadOperation,
        url: URL,
        context: FileSystemErrorContext
    )

    /// Interior corruption was detected mid-segment.
    ///
    /// Carries the byte offset where the corruption was first
    /// observed and a ``InternalCorruptionClass`` per
    /// `Docs/FileFormatSpec.md` ("Corruption/Recovery"). The read
    /// path hard-stops on this case.
    case interiorCorruption(
        segmentURL: URL,
        byteOffset: UInt64,
        classification: InternalCorruptionClass
    )
}

/// The step in the read-side pipeline that surfaced a file-system
/// failure.
internal enum InternalReadOperation: String, Sendable, Equatable {
    /// Enumerating segment files in the configured directory.
    case enumerateSegments
    /// Opening a segment file for read.
    case openSegment
    /// Reading bytes from an open segment file.
    case readSegmentBytes
}

/// The class of interior corruption observed during byte-stable
/// scanning.
///
/// Classes correspond 1:1 to the recovery taxonomy in
/// `Docs/FileFormatSpec.md` ("Corruption/Recovery") and to the
/// corpus fixtures under `Tests/.../Fixtures/Corpus`.
internal enum InternalCorruptionClass: Sendable, Equatable {
    /// A scanned byte boundary was not a valid UTF-8 sequence.
    case malformedUTF8
    /// JSON parsing failed within an LF-terminated line.
    case malformedJSON
    /// JSON parsed but the top-level value was not an object.
    case nonObjectJSON
    /// The envelope JSON object, or its `hints` object, contained a
    /// duplicate member.
    case duplicateJSONMember
    /// The envelope's `payload` field was not standard base64.
    case malformedBase64
    /// JSON parsed as an object but did not satisfy the envelope
    /// shape required by `Docs/FileFormatSpec.md`.
    case invalidEnvelope
    /// The line delimiter was not LF (e.g. CRLF, mixed CRLF/LF).
    case invalidDelimiter
}
