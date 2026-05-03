import Foundation
import LoggerPersistence

/// File-backed `PersistentLogStore`. Each `append(_:)` admits one
/// canonical LF-terminated NDJSON envelope line into a single
/// segment file.
///
/// Wire format is owned by `Docs/FileFormatSpec.md`. The actor
/// serializes file-handle I/O. Producer-owned sequence metadata
/// is preserved unchanged by the store.
public actor FileLogStore: PersistentLogStore {
    /// Encoded NDJSON line byte cap per `Docs/FileFormatSpec.md`
    /// ("Payload and Bounds"): an envelope line, including base64
    /// payload, JSON punctuation, and trailing LF, must not exceed
    /// 2 MiB.
    public static let maxEncodedLineBytes = 2_097_152

    /// Single-segment file name used by this store. Segment topology
    /// is outside the portable compatibility contract per
    /// `Docs/FileFormatSpec.md` ("Operational Notes").
    private static let segmentFileName = "log.ndjson"

    private let configuration: Configuration
    private let lineEncoder = CanonicalEnvelopeLineEncoder()
    private var fileHandle: FileHandle?

    /// Creates a file-backed store.
    ///
    /// The store does not open a file handle eagerly; the segment
    /// file is created on the first `append(_:)` call.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Encodes the envelope as one canonical LF-terminated NDJSON
    /// envelope line and admits it as exactly one accepted line in
    /// the segment file's recoverable prefix.
    ///
    /// - Throws: ``FileLogStoreError`` on file-system failure,
    ///   pre-admission validation failure, or implementation
    ///   invariant violation. Validation failures and encoding
    ///   failures occur before any storage mutation; rejected
    ///   envelopes never extend the recoverable prefix.
    public func append(
        _ envelope: PersistentLogEnvelope
    ) async throws(FileLogStoreError) {
        let segmentURL = segmentURL
        let lineBytes = try canonicalLineBytes(for: envelope, segmentURL: segmentURL)
        try Self.validateTrailingLF(lineBytes)
        guard lineBytes.count <= Self.maxEncodedLineBytes else {
            throw .invalidEnvelope(reason: .encodedEnvelopeLineTooLarge(
                limitBytes: Self.maxEncodedLineBytes,
                actualBytes: lineBytes.count
            ))
        }
        try Self.validateNoInteriorLF(lineBytes)
        let handle = try openHandleIfNeeded(segmentURL: segmentURL)
        do {
            try handle.write(contentsOf: lineBytes)
        } catch {
            throw .operationFailed(
                operation: .appendEnvelopeBytes,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Verifies the encoded line ends with the canonical trailing
    /// LF per `Docs/FileFormatSpec.md` ("Implementation Invariant
    /// Diagnostics"). Constant-time; safe to run before the
    /// encoded-line size cap.
    static func validateTrailingLF(
        _ bytes: Data
    ) throws(FileLogStoreError) {
        guard bytes.last == 0x0A else {
            throw .implementationInvariantViolation(
                violation: .encodedEnvelopeMissingTrailingLF
            )
        }
    }

    /// Verifies the encoded line contains no LF before its
    /// terminal LF. Linear scan; run only after the encoded-line
    /// size cap so rejected oversized payloads are not scanned.
    static func validateNoInteriorLF(
        _ bytes: Data
    ) throws(FileLogStoreError) {
        if bytes.dropLast().contains(0x0A) {
            throw .implementationInvariantViolation(
                violation: .encodedEnvelopeContainsInteriorLF
            )
        }
    }

    /// Best-effort local synchronization boundary for accepted
    /// appends.
    ///
    /// Preserves but never expands recoverable visibility per
    /// `Docs/FileFormatSpec.md` ("Flush"). Returns immediately when
    /// no segment file has been opened on this instance.
    public func flush() async throws(FileLogStoreError) {
        guard let handle = fileHandle else { return }
        do {
            try handle.synchronize()
        } catch {
            throw .operationFailed(
                operation: .flushBoundary,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private var segmentURL: URL {
        configuration.directory.appendingPathComponent(Self.segmentFileName)
    }

    private func canonicalLineBytes(
        for envelope: PersistentLogEnvelope,
        segmentURL: URL
    ) throws(FileLogStoreError) -> Data {
        do {
            return try lineEncoder.encode(envelope)
        } catch {
            // Encoder failures are projected into the store-local
            // `.encodeEnvelope` operation boundary while preserving
            // the underlying error's domain, code, and description.
            throw .operationFailed(
                operation: .encodeEnvelope,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private func openHandleIfNeeded(
        segmentURL: URL
    ) throws(FileLogStoreError) -> FileHandle {
        if let handle = fileHandle { return handle }
        let fileManager = FileManager.default
        try createDirectoryIfNeeded(fileManager: fileManager)
        try createSegmentIfNeeded(segmentURL: segmentURL, fileManager: fileManager)
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: segmentURL)
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
        try trimTrailingSuffixAndPosition(handle: handle, segmentURL: segmentURL)
        fileHandle = handle
        return handle
    }

    /// Positions `handle` at the byte after the segment's last LF
    /// and truncates any trailing bytes that follow it so the
    /// next append cannot incorporate an undefined suffix into a
    /// physical LF-terminated line.
    ///
    /// This is the M3.3.0 last-complete-line boundary for suffix
    /// trimming. It does not validate that prior complete lines
    /// are valid canonical envelope lines; corruption-aware
    /// recoverable-prefix discovery is the M3.3.2 contract.
    private func trimTrailingSuffixAndPosition(
        handle: FileHandle,
        segmentURL: URL
    ) throws(FileLogStoreError) {
        let boundary: UInt64
        do {
            let size = try handle.seekToEnd()
            boundary = try Self.lastLineTerminatorOffset(in: handle, size: size)
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
        do {
            try handle.truncate(atOffset: boundary)
            try handle.seek(toOffset: boundary)
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Returns the byte offset immediately after the segment's
    /// last LF, or `0` when no LF is present. Scans backwards in
    /// 4 KB chunks; does not parse interior content.
    private static func lastLineTerminatorOffset(
        in handle: FileHandle,
        size: UInt64
    ) throws -> UInt64 {
        if size == 0 { return 0 }
        let chunkSize: UInt64 = 4096
        var scanEnd = size
        while scanEnd > 0 {
            let chunkStart = scanEnd > chunkSize ? scanEnd - chunkSize : 0
            let chunkLen = Int(scanEnd - chunkStart)
            try handle.seek(toOffset: chunkStart)
            let chunk = try readExactly(handle: handle, count: chunkLen)
            if let lfIndex = chunk.lastIndex(of: 0x0A) {
                return chunkStart + UInt64(lfIndex) + 1
            }
            if chunkStart == 0 { return 0 }
            scanEnd = chunkStart
        }
        return 0
    }

    /// Reads exactly `count` bytes from `handle`, looping on
    /// short `read(upToCount:)` returns. Throws an I/O error if
    /// the file ends before `count` bytes are produced.
    private static func readExactly(
        handle: FileHandle,
        count: Int
    ) throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            let remaining = count - accumulated.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty
            else {
                throw POSIXError(.EIO)
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    private func createDirectoryIfNeeded(
        fileManager: FileManager
    ) throws(FileLogStoreError) {
        do {
            try fileManager.createDirectory(
                at: configuration.directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private func createSegmentIfNeeded(
        segmentURL: URL,
        fileManager: FileManager
    ) throws(FileLogStoreError) {
        guard !fileManager.fileExists(atPath: segmentURL.path) else { return }
        guard fileManager.createFile(atPath: segmentURL.path, contents: nil) else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(
                    domain: "LoggerFilePersistence",
                    code: nil,
                    description: "FileManager.createFile returned false for the segment file URL"
                )
            )
        }
    }
}

extension FileLogStore {
    /// Configuration for ``FileLogStore``. Only the
    /// segment-directory URL is exposed.
    public struct Configuration: Sendable {
        /// The directory under which the store writes its NDJSON
        /// segment file. Created on first append if it does not
        /// already exist.
        public var directory: URL

        public init(directory: URL) {
            self.directory = directory
        }
    }
}
