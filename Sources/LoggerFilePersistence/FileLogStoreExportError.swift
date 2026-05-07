import Foundation

/// Public error surface for ``FileLogStore/exportLogs(to:)``.
///
/// Owned by `LoggerFilePersistence`; the deferred portable
/// `ExportableLogStore` protocol will introduce its own protocol-level
/// error in a later milestone alongside `removeExportedLogs()`.
public enum FileLogStoreExportError: Error, Sendable, Equatable {
    /// A file-system step in the export pipeline failed.
    case operationFailed(
        operation: FileLogStoreExportOperation,
        url: URL,
        context: FileSystemErrorContext
    )

    /// Interior corruption was detected while reading a segment;
    /// the export aborts before any bytes are visible at the
    /// destination URL.
    case interiorCorruption(
        segmentURL: URL,
        byteOffset: UInt64,
        classification: FileLogStoreExportCorruptionClass
    )

    /// The destination URL or its parent does not satisfy the
    /// no-overwrite atomic-commit precondition.
    case invalidDestination(reason: FileLogStoreExportInvalidDestinationReason)
}

/// File-system step in the byte-stable export pipeline.
public enum FileLogStoreExportOperation: String, Sendable, Equatable {
    case enumerateSegments
    case openSegment
    case readSegmentBytes
    case openDestinationParent
    case validateDestination
    case createTemporaryDestination
    case writeTemporaryDestinationBytes
    case syncTemporaryDestination
    case closeTemporaryDestination
    case commitDestination
}

// swiftlint:disable type_name
// Reason: Public API name locked by spec-owner gate v2; renaming is a public-API break.

/// Reason the destination URL or its parent fails the
/// pre-commit topology contract.
public enum FileLogStoreExportInvalidDestinationReason: Sendable, Equatable {
    /// Final URL exists as a regular file.
    case alreadyExistsAsRegularFile
    /// Final URL exists as a symlink.
    case alreadyExistsAsSymlink
    /// Final URL exists as a directory.
    case alreadyExistsAsDirectory
    /// Final URL exists as some other non-regular topology
    /// (fifo, socket, device).
    case alreadyExistsAsNonRegular
    /// Parent directory of final URL is absent.
    case parentDirectoryAbsent
    /// Parent path exists but cannot be opened as a directory.
    case parentDirectoryInvalid
}

// swiftlint:enable type_name

/// Public corruption taxonomy surfaced when an export aborts on
/// interior corruption. Mirrors the internal classification 1:1
/// and is part of the file-store export compatibility contract.
public enum FileLogStoreExportCorruptionClass: Sendable, Equatable {
    case malformedUTF8
    case malformedJSON
    case nonObjectJSON
    case duplicateJSONMember
    case malformedBase64
    case invalidEnvelope
    case invalidDelimiter
}

extension FileLogStoreExportCorruptionClass {
    /// Maps the internal corruption class to its public surface.
    /// Stable mapping; new internal cases require a public addition
    /// before they can be projected.
    internal init(_ internalClass: InternalCorruptionClass) {
        switch internalClass {
        case .malformedUTF8: self = .malformedUTF8
        case .malformedJSON: self = .malformedJSON
        case .nonObjectJSON: self = .nonObjectJSON
        case .duplicateJSONMember: self = .duplicateJSONMember
        case .malformedBase64: self = .malformedBase64
        case .invalidEnvelope: self = .invalidEnvelope
        case .invalidDelimiter: self = .invalidDelimiter
        }
    }
}
