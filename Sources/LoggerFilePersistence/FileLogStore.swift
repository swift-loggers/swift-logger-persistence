import Foundation
import LoggerPersistence

/// File-backed `PersistentLogStore`. Each `append(_:)` admits one
/// canonical LF-terminated NDJSON envelope line into a segment file.
///
/// Wire format is owned by `Docs/FileFormatSpec.md`. Segment topology
/// (naming, rotation boundaries, retention) is a policy contract,
/// not portable wire format. The actor serializes file-handle I/O.
/// Producer-owned sequence metadata is preserved unchanged by the
/// store.
public actor FileLogStore: PersistentLogStore {
    /// Encoded NDJSON line byte cap per `Docs/FileFormatSpec.md`
    /// ("Payload and Bounds"): an envelope line, including base64
    /// payload, JSON punctuation, and trailing LF, must not exceed
    /// 2 MiB.
    public static let maxEncodedLineBytes = 2_097_152

    /// Filename used when ``RotationPolicy/never`` is configured.
    private static let unrotatedSegmentFileName = "log.ndjson"

    /// Filename prefix shared by all rotated segments.
    private static let rotatedSegmentFileNamePrefix = "log."

    /// Filename suffix shared by all rotated segments.
    private static let rotatedSegmentFileNameSuffix = ".ndjson"

    /// Minimum decimal width for rotated segment sequences.
    /// Reopen discovery is width-independent.
    private static let rotatedSegmentSequenceWidth = 6

    private let configuration: Configuration
    private let lineEncoder = CanonicalEnvelopeLineEncoder()
    private var activeSegment: ActiveSegment?
    /// Handles whose `close()` failed during a rotation transition.
    /// Retained on the actor so a transient close failure does not
    /// orphan a file descriptor; drained on each later admit/flush
    /// boundary and on `deinit` as a best-effort retry.
    private var pendingCloseHandles: [FileHandle] = []

    /// Creates a file-backed store.
    ///
    /// The store does not open a file handle eagerly; the segment
    /// file is created on the first `append(_:)` call.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        try? activeSegment?.handle.close()
        for handle in pendingCloseHandles {
            try? handle.close()
        }
    }

    /// Encodes the envelope as one canonical LF-terminated NDJSON
    /// envelope line and admits it as exactly one accepted line in
    /// a segment file's recoverable prefix.
    ///
    /// When the configured ``RotationPolicy`` would be exceeded
    /// by the next line, the store rotates to the next segment.
    /// The append is preserved as exactly one accepted line in
    /// exactly one segment; rotation never splits a line across
    /// segments per `Docs/FileFormatSpec.md` ("Append Rotation
    /// Interaction").
    ///
    /// - Throws: ``FileLogStoreError`` on file-system failure,
    ///   pre-admission validation failure, or implementation
    ///   invariant violation. Validation failures and encoding
    ///   failures occur before any storage mutation; rejected
    ///   envelopes never extend the recoverable prefix.
    public func append(
        _ envelope: PersistentLogEnvelope
    ) async throws(FileLogStoreError) {
        drainPendingCloseHandles()
        let lineBytes = try canonicalLineBytes(for: envelope)
        try Self.validateTrailingLF(lineBytes)
        guard lineBytes.count <= Self.maxEncodedLineBytes else {
            throw .invalidEnvelope(reason: .encodedEnvelopeLineTooLarge(
                limitBytes: Self.maxEncodedLineBytes,
                actualBytes: lineBytes.count
            ))
        }
        try Self.validateNoInteriorLF(lineBytes)
        var active = try ensureWritableSegment(for: lineBytes)
        do {
            try active.handle.write(contentsOf: lineBytes)
            active.size += UInt64(lineBytes.count)
            activeSegment = active
        } catch {
            // The handle's offset and the segment's tail are now
            // in an undefined state: the underlying write may have
            // committed a partial prefix before failing. Discard
            // the active segment so the next admit reopens through
            // the suffix-trim path, which truncates any trailing
            // non-LF bytes before admitting a fresh line.
            do {
                try active.handle.close()
            } catch {
                pendingCloseHandles.append(active.handle)
            }
            activeSegment = nil
            throw .operationFailed(
                operation: .appendEnvelopeBytes,
                url: active.url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Verifies the encoded line ends with the canonical trailing
    /// LF per `Docs/FileFormatSpec.md` ("Implementation Invariant
    /// Diagnostics"). Safe to run before the encoded-line size cap.
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
    /// terminal LF. Run only after the encoded-line size cap so
    /// rejected oversized payloads are not scanned.
    static func validateNoInteriorLF(
        _ bytes: Data
    ) throws(FileLogStoreError) {
        if bytes.dropLast().contains(0x0A) {
            throw .implementationInvariantViolation(
                violation: .encodedEnvelopeContainsInteriorLF
            )
        }
    }

    /// Best-effort local synchronization boundary for accepted appends.
    public func flush() async throws(FileLogStoreError) {
        drainPendingCloseHandles()
        guard let active = activeSegment else { return }
        do {
            try active.handle.synchronize()
        } catch {
            throw .operationFailed(
                operation: .flushBoundary,
                url: active.url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private func canonicalLineBytes(
        for envelope: PersistentLogEnvelope
    ) throws(FileLogStoreError) -> Data {
        do {
            return try lineEncoder.encode(envelope)
        } catch {
            // Project encoder failures onto `.encodeEnvelope`.
            throw .operationFailed(
                operation: .encodeEnvelope,
                url: activeSegment?.url ?? configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Returns the segment that will receive the next
    /// admitted line, rotating if required by policy.
    private func ensureWritableSegment(
        for lineBytes: Data
    ) throws(FileLogStoreError) -> ActiveSegment {
        let current: ActiveSegment
        if let active = activeSegment {
            current = active
        } else {
            // Reopen may immediately require rotation.
            current = try openInitialSegment()
            activeSegment = current
        }
        if needsRotation(current: current, addingLineBytes: lineBytes.count) {
            return try rotateToNextSegment(after: current)
        }
        return current
    }

    private func needsRotation(
        current: ActiveSegment,
        addingLineBytes lineBytesCount: Int
    ) -> Bool {
        switch configuration.rotation.kind {
        case .never:
            return false
        case let .bySize(maxSegmentBytes):
            let (sum, overflow) = current.size
                .addingReportingOverflow(UInt64(lineBytesCount))
            // Overflow requires rotation.
            guard !overflow else { return true }
            return sum > UInt64(maxSegmentBytes)
        }
    }

    /// Reopen resumes from the highest discovered rotated segment.
    private func openInitialSegment() throws(FileLogStoreError) -> ActiveSegment {
        let fileManager = FileManager.default
        try createDirectoryIfNeeded(fileManager: fileManager)
        switch configuration.rotation.kind {
        case .never:
            let url = configuration.directory.appendingPathComponent(Self.unrotatedSegmentFileName)
            return try openNewSegment(url: url, sequence: nil, fileManager: fileManager)
        case .bySize:
            let sequence = try discoverHighestRotatedSegmentSequence(fileManager: fileManager) ?? 1
            let url = rotatedSegmentURL(sequence: sequence)
            return try openNewSegment(url: url, sequence: sequence, fileManager: fileManager)
        }
    }

    private func rotateToNextSegment(
        after current: ActiveSegment
    ) throws(FileLogStoreError) -> ActiveSegment {
        let fileManager = FileManager.default
        let baseSequence = current.sequence ?? 0
        let (nextSequence, didOverflow) = baseSequence.addingReportingOverflow(1)
        guard !didOverflow else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: current.url,
                context: FileSystemErrorContext(
                    domain: "LoggerFilePersistence",
                    code: nil,
                    description: "rotated segment sequence overflow"
                )
            )
        }
        let url = rotatedSegmentURL(sequence: nextSequence)
        // Activate the next segment before closing the previous
        // handle; close failures are retained for retry.
        let next = try openNewSegment(url: url, sequence: nextSequence, fileManager: fileManager)
        activeSegment = next
        do {
            try current.handle.close()
        } catch {
            pendingCloseHandles.append(current.handle)
            throw .operationFailed(
                operation: .closeWritableSegment,
                url: current.url,
                context: FileSystemErrorContext(from: error)
            )
        }
        return next
    }

    private func openNewSegment(
        url: URL,
        sequence: UInt64?,
        fileManager: FileManager
    ) throws(FileLogStoreError) -> ActiveSegment {
        try ensureRegularFileSegmentExists(segmentURL: url, fileManager: fileManager)
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
        // If trim/seek fails before ownership transfer, the
        // opened handle is closed or retained for retry.
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
                do {
                    try handle.close()
                } catch {
                    pendingCloseHandles.append(handle)
                }
            }
        }
        try trimTrailingSuffixAndPosition(handle: handle, segmentURL: url)
        let position: UInt64
        do {
            position = try handle.offset()
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
        let active = ActiveSegment(handle: handle, url: url, sequence: sequence, size: position)
        ownershipTransferred = true
        return active
    }

    /// Returns the rotated-segment URL for `sequence`.
    private func rotatedSegmentURL(sequence: UInt64) -> URL {
        var digits = String(sequence)
        while digits.utf8.count < Self.rotatedSegmentSequenceWidth {
            digits = "0" + digits
        }
        let name = Self.rotatedSegmentFileNamePrefix
            + digits
            + Self.rotatedSegmentFileNameSuffix
        return configuration.directory.appendingPathComponent(name)
    }

    /// Trims bytes after the last LF and seeks to the append
    /// boundary.
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
}

extension FileLogStore {
    /// Returns the highest rotated-segment sequence present in
    /// the configured directory, or `nil` when none exist.
    private func discoverHighestRotatedSegmentSequence(
        fileManager: FileManager
    ) throws(FileLogStoreError) -> UInt64? {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: configuration.directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
        var highest: UInt64?
        for entry in entries {
            let isRegularFile: Bool?
            do {
                isRegularFile = try entry
                    .resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile
            } catch {
                throw .operationFailed(
                    operation: .openWritableSegment,
                    url: entry,
                    context: FileSystemErrorContext(from: error)
                )
            }
            guard isRegularFile == true else { continue }
            let name = entry.lastPathComponent
            guard name.hasPrefix(Self.rotatedSegmentFileNamePrefix),
                  name.hasSuffix(Self.rotatedSegmentFileNameSuffix)
            else { continue }
            let middle = name
                .dropFirst(Self.rotatedSegmentFileNamePrefix.count)
                .dropLast(Self.rotatedSegmentFileNameSuffix.count)
            guard !middle.isEmpty,
                  middle.utf8.allSatisfy(Self.isASCIIDigit),
                  let sequence = UInt64(middle),
                  sequence > 0
            else { continue }
            highest = max(highest ?? 0, sequence)
        }
        return highest
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
        let isDirectory: Bool?
        do {
            isDirectory = try configuration.directory
                .resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory
        } catch {
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
        guard isDirectory == true else {
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: "LoggerFilePersistence",
                    code: nil,
                    description: "configured directory URL exists but is not a directory"
                )
            )
        }
    }

    private func ensureRegularFileSegmentExists(
        segmentURL: URL,
        fileManager: FileManager
    ) throws(FileLogStoreError) {
        if fileManager.fileExists(atPath: segmentURL.path) {
            try validateSegmentIsRegularFile(segmentURL: segmentURL)
            return
        }
        guard fileManager.createFile(atPath: segmentURL.path, contents: nil) else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(
                    domain: "LoggerFilePersistence",
                    code: nil,
                    description: "segment file could not be created"
                )
            )
        }
        try validateSegmentIsRegularFile(segmentURL: segmentURL)
    }

    private func validateSegmentIsRegularFile(
        segmentURL: URL
    ) throws(FileLogStoreError) {
        let isRegularFile: Bool?
        do {
            isRegularFile = try segmentURL
                .resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
        guard isRegularFile == true else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(
                    domain: "LoggerFilePersistence",
                    code: nil,
                    description: "segment URL exists but is not a regular file"
                )
            )
        }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private func drainPendingCloseHandles() {
        guard !pendingCloseHandles.isEmpty else { return }
        let handles = pendingCloseHandles
        var retained: [FileHandle] = []
        for handle in handles {
            do {
                try handle.close()
            } catch {
                retained.append(handle)
            }
        }
        pendingCloseHandles = retained
    }
}

extension FileLogStore {
    /// Active writable segment.
    fileprivate struct ActiveSegment {
        let handle: FileHandle
        let url: URL
        /// Rotated-segment sequence; `nil` under `.never`.
        let sequence: UInt64?
        var size: UInt64
    }
}

extension FileLogStore {
    /// Returns the byte offset immediately after the segment's
    /// last LF, or `0` when no LF is present.
    private static func lastLineTerminatorOffset(
        in handle: FileHandle,
        size: UInt64
    ) throws -> UInt64 {
        if size == 0 { return 0 }
        let chunkSize: UInt64 = 4096
        var scanEnd = size
        while true {
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
    }

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
}

extension FileLogStore {
    /// Construction-time configuration for ``FileLogStore``.
    public struct Configuration: Sendable {
        /// Directory containing segment files.
        public var directory: URL

        /// Segment rotation policy.
        public var rotation: RotationPolicy

        public init(directory: URL) {
            self.directory = directory
            rotation = .never
        }

        public init(directory: URL, rotation: RotationPolicy) {
            self.directory = directory
            self.rotation = rotation
        }
    }
}

// MARK: - TEST-ONLY

internal enum TestSeamFailure: Error, Sendable {
    case noActiveSegment
}

// TEST-ONLY failure-injection seams.
extension FileLogStore {
    // swiftlint:disable identifier_name

    internal func _forceCloseActiveHandleForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        do {
            try active.handle.close()
            activeSegment = nil
        } catch {
            pendingCloseHandles.append(active.handle)
            activeSegment = nil
            throw error
        }
    }

    /// Deliberately leaves `activeSegment` pointing at a
    /// closed handle to exercise invalid-handle recovery.
    internal func _forceCloseActiveHandleLeavingInvalidReferenceForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        let handle = active.handle
        try handle.close()
        activeSegment = ActiveSegment(
            handle: handle,
            url: active.url,
            sequence: active.sequence,
            size: active.size
        )
    }

    internal func _injectPendingCloseHandleForTesting(_ handle: FileHandle) {
        pendingCloseHandles.append(handle)
    }

    internal var _pendingCloseHandleCountForTesting: Int {
        pendingCloseHandles.count
    }

    // swiftlint:enable identifier_name
}
