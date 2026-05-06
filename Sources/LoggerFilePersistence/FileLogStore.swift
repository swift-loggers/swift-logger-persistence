import Darwin
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

    /// Minimum decimal width for rotated segment sequences.
    /// Reopen discovery is width-independent.
    private static let rotatedSegmentSequenceWidth = 6

    /// Module-internal so the export extension in a sibling file
    /// can resolve the configured root path under the same actor
    /// mutex.
    internal let configuration: Configuration
    private let lineEncoder = CanonicalEnvelopeLineEncoder()
    private var activeSegment: ActiveSegment?
    /// Held configured-root descriptor. Opened once on the first
    /// admit and reused for every subsequent segment open / rotation
    /// so a path-component swap of `configuration.directory` after
    /// the descriptor is held cannot redirect writes to a different
    /// real directory. Module-internal so the export extension in a
    /// sibling file can borrow it under the same actor mutex.
    internal var writerRoot: SegmentRoot?
    /// Handles whose `close()` failed during a rotation transition.
    /// Retained on the actor so a transient close failure does not
    /// orphan a file descriptor; drained on each later admit/flush
    /// boundary and on `deinit` as a best-effort retry.
    private var pendingCloseHandles: [FileHandle] = []

    /// TEST-ONLY hook fired before each `openSegmentForWriting`
    /// call (initial open and rotation) once the held writer root
    /// is in hand. Lets tests deterministically race a path-swap
    /// against `openat(rootFD, ...)`. A throw surfaces as
    /// `.operationFailed(.openWritableSegment)`.
    private var onBeforeOpenWritableSegmentForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY hook fired between the post-create root
    /// `lstat(2)` snapshot and the descriptor open. Lets tests
    /// deterministically race a path-component swap against
    /// `SegmentRoot.open` so the post-open identity check sees a
    /// different inode and rejects.
    private var onBeforeWriterRootOpenForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY hook fired by the export critical section after
    /// all segment bytes have been written to the temp file but
    /// before `fsync(temp)`. Lets tests inject a write-failure
    /// equivalent so the cleanup contract can be exercised
    /// without a filesystem-level fault. Module-internal so the
    /// export extension in a sibling file can read it under the
    /// same actor mutex.
    internal var onAfterWritingTemporaryBytesForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY hook fired by the export critical section after
    /// the temp file has been closed and immediately before the
    /// atomic `renameatx_np(... RENAME_EXCL)` commit. Lets tests
    /// race the destination URL deterministically (e.g. plant a
    /// pre-existing entry between final pre-check and commit) so
    /// the no-overwrite + EEXIST re-probe paths are exercised.
    /// Throws so test setup failures surface as a typed export
    /// error instead of silently corrupting the test's premise.
    internal var onBeforeCommitForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY hook fired at the end of `append` after the
    /// admitted bytes have reached the active segment. Lets tests
    /// observe append completion without a sleep when proving
    /// single-flight serialization against `exportLogs(to:)`.
    internal var onAfterAppendForTesting: (@Sendable () -> Void)?

    /// TEST-ONLY hook fired at the very first instruction of
    /// `append`, after the call has acquired the actor mutex but
    /// before any work runs. Combined with
    /// ``onAfterAppendForTesting`` this lets tests record an
    /// `[append-entered, append-completed]` interval that the
    /// actor mutex guarantees never overlaps an export's gate
    /// interval.
    internal var onBeforeAppendForTesting: (@Sendable () -> Void)?

    /// TEST-ONLY hook fired at the start of
    /// `closeExportTemporary`. A throw simulates a `close(2)`
    /// failure deterministically so the cleanup contract can be
    /// exercised without a filesystem-level fault. The
    /// descriptor is best-effort closed before the hook's error
    /// is projected onto `.closeTemporaryDestination`.
    internal var onCloseTemporaryDestinationForTesting: (@Sendable () throws -> Void)?

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
        writerRoot?.close()
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
        onBeforeAppendForTesting?()
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
        onAfterAppendForTesting?()
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

    /// Reopen resumes from the highest discovered rotated segment
    /// using the held writer-root descriptor; both discovery and
    /// segment open are descriptor-relative against the same root.
    private func openInitialSegment() throws(FileLogStoreError) -> ActiveSegment {
        let root = try ensureWriterRoot()
        switch configuration.rotation.kind {
        case .never:
            let url = SegmentEnumeration.unrotatedSegmentURL(in: configuration.directory)
            return try openNewSegment(root: root, url: url, sequence: nil)
        case .bySize:
            let sequence = try discoverHighestRotatedSegmentSequence(root: root) ?? 1
            let url = rotatedSegmentURL(sequence: sequence)
            return try openNewSegment(root: root, url: url, sequence: sequence)
        }
    }

    private func rotateToNextSegment(
        after current: ActiveSegment
    ) throws(FileLogStoreError) -> ActiveSegment {
        let baseSequence = current.sequence ?? 0
        let (nextSequence, didOverflow) = baseSequence.addingReportingOverflow(1)
        guard !didOverflow else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: current.url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "rotated segment sequence overflow"
                )
            )
        }
        let root = try ensureWriterRoot()
        let url = rotatedSegmentURL(sequence: nextSequence)
        // Activate the next segment before closing the previous
        // handle; close failures are retained for retry. The next
        // segment opens through the same held descriptor as the
        // previous one — rotation does not re-resolve the path.
        let next = try openNewSegment(root: root, url: url, sequence: nextSequence)
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
        root: SegmentRoot,
        url: URL,
        sequence: UInt64?
    ) throws(FileLogStoreError) -> ActiveSegment {
        try fireBeforeOpenWritableSegmentSeam(url: url)
        let handle: FileHandle
        do {
            handle = try root.openSegmentForWriting(url: url)
        } catch {
            throw FileLogStoreError(projecting: error, onto: .openWritableSegment)
        }
        // If trim/seek fails before ownership transfer, the
        // opened handle is closed or retained for deferred close.
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
        SegmentEnumeration.rotatedSegmentURL(
            in: configuration.directory,
            sequence: sequence,
            minimumWidth: Self.rotatedSegmentSequenceWidth
        )
    }

    /// Positions `handle` at the recoverable-prefix boundary,
    /// truncating trailing partial bytes and failing closed on
    /// interior corruption.
    private func trimTrailingSuffixAndPosition(
        handle: FileHandle,
        segmentURL: URL
    ) throws(FileLogStoreError) {
        // Reopen positions the writer at the recoverable-prefix boundary.
        let resolution: RecoverablePrefixScanner.BoundaryResolution
        do {
            resolution = try RecoverablePrefixScanner.resolveBoundary(
                handle: handle,
                segmentURL: segmentURL
            )
        } catch {
            throw FileLogStoreError(
                projecting: error,
                onto: .openWritableSegment
            )
        }
        let boundary: UInt64
        switch resolution {
        case let .boundary(value):
            boundary = value
        case .interiorCorruption:
            throw .operationFailed(
                operation: .openWritableSegment,
                url: segmentURL,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "interiorCorruption"
                )
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
    /// Returns the highest rotated-segment sequence for writer reopen.
    private func discoverHighestRotatedSegmentSequence(
        root: SegmentRoot
    ) throws(FileLogStoreError) -> UInt64? {
        do {
            return try root.highestRotatedSegmentSequence()
        } catch {
            throw FileLogStoreError(
                projecting: error,
                onto: .openWritableSegment
            )
        }
    }

    /// Creates, validates, opens, and identity-binds the configured writer root.
    private func ensureWriterRoot() throws(FileLogStoreError) -> SegmentRoot {
        if let root = writerRoot { return root }
        let identity = try createDirectoryIfNeeded(fileManager: FileManager.default)
        try fireBeforeWriterRootOpenSeam()
        let opened: SegmentRoot?
        do {
            opened = try SegmentRoot.open(directory: configuration.directory)
        } catch {
            throw FileLogStoreError(projecting: error, onto: .openWritableSegment)
        }
        guard let root = opened else {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "configuredDirectoryAbsentAfterCreate"
                )
            )
        }
        do {
            try root.validateIdentity(matches: identity)
        } catch {
            root.close()
            throw FileLogStoreError(projecting: error, onto: .openWritableSegment)
        }
        writerRoot = root
        return root
    }

    private func fireBeforeWriterRootOpenSeam() throws(FileLogStoreError) {
        guard let hook = onBeforeWriterRootOpenForTesting else { return }
        do {
            try hook()
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private func fireBeforeOpenWritableSegmentSeam(
        url: URL
    ) throws(FileLogStoreError) {
        guard let hook = onBeforeOpenWritableSegmentForTesting else { return }
        do {
            try hook()
        } catch {
            throw .operationFailed(
                operation: .openWritableSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Creates the configured directory and returns its `lstat(2)` identity.
    private func createDirectoryIfNeeded(
        fileManager: FileManager
    ) throws(FileLogStoreError) -> DirectoryIdentity {
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
        // Capture root identity without following symlinks.
        var statBuf = stat()
        let result = configuration.directory.path.withCString { cPath in
            lstat(cPath, &statBuf)
        }
        if result != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "lstatFailed"
                )
            )
        }
        guard (statBuf.st_mode & S_IFMT) == S_IFDIR else {
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "configured directory URL exists but is not a directory"
                )
            )
        }
        return DirectoryIdentity(statBuf)
    }

    /// Module-internal so the export extension in a sibling file
    /// can flush pending closes at the start of an export under
    /// the same actor mutex.
    internal func drainPendingCloseHandles() {
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
    case handleAlreadyPendingClose
}

// TEST-ONLY failure-injection seams.
extension FileLogStore {
    // swiftlint:disable identifier_name

    /// TEST-ONLY: closes the active handle and clears `activeSegment`.
    /// Failed close is retained for retry.
    ///
    /// Invariant: active handle must not already be pending close.
    internal func _forceCloseActiveHandleForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        try ensureHandleNotPendingCloseForTesting(active.handle)
        do {
            try active.handle.close()
            activeSegment = nil
        } catch {
            pendingCloseHandles.append(active.handle)
            activeSegment = nil
            throw error
        }
    }

    /// TEST-ONLY: leaves `activeSegment` pointing at a closed handle.
    ///
    /// Invariant: active handle must not already be pending close.
    internal func _forceCloseActiveHandleLeavingInvalidReferenceForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        let handle = active.handle
        try ensureHandleNotPendingCloseForTesting(handle)
        try handle.close()
        activeSegment = ActiveSegment(
            handle: handle,
            url: active.url,
            sequence: active.sequence,
            size: active.size
        )
    }

    /// TEST-ONLY: injects a handle into the pending-close retry queue.
    /// The handle must not already be present in the queue.
    internal func _injectPendingCloseHandleForTesting(_ handle: FileHandle) throws {
        try ensureHandleNotPendingCloseForTesting(handle)
        pendingCloseHandles.append(handle)
    }

    internal var _pendingCloseHandleCountForTesting: Int {
        pendingCloseHandles.count
    }

    /// TEST-ONLY: installs a hook that fires immediately before each
    /// `openSegmentForWriting` call (initial open and rotation) once
    /// the held writer root is in hand. A throw from the hook is
    /// projected onto `.openWritableSegment`.
    internal func _setOnBeforeOpenWritableSegmentForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeOpenWritableSegmentForTesting = hook
    }

    /// TEST-ONLY: installs a hook that fires between the post-create
    /// root `lstat` snapshot and the `SegmentRoot.open` call. A
    /// throw from the hook is projected onto `.openWritableSegment`.
    internal func _setOnBeforeWriterRootOpenForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeWriterRootOpenForTesting = hook
    }

    /// TEST-ONLY: installs a hook that fires inside the export
    /// critical section after all segment bytes have been written
    /// to the temp file but before `fsync(temp)`. A throw from the
    /// hook is projected onto
    /// `.writeTemporaryDestinationBytes` so cleanup can be
    /// asserted without a real write fault.
    internal func _setOnAfterWritingTemporaryBytesForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onAfterWritingTemporaryBytesForTesting = hook
    }

    /// TEST-ONLY: installs a hook fired inside the export critical
    /// section after the temp file is closed and immediately
    /// before the atomic commit, used to plant a destination
    /// entry between final pre-check and `renameatx_np`. A throw
    /// projects to `.operationFailed(.commitDestination)`.
    internal func _setOnBeforeCommitForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onBeforeCommitForTesting = hook
    }

    /// TEST-ONLY: installs a hook fired at the end of `append`
    /// after admitted bytes reach the active segment. Used to
    /// observe append completion ordering against export.
    internal func _setOnAfterAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onAfterAppendForTesting = hook
    }

    /// TEST-ONLY: installs a hook fired at the first instruction
    /// of `append`, immediately after the call acquires the actor
    /// mutex. Pairs with `_setOnAfterAppendForTesting` to record
    /// the actor-isolated interval for single-flight proofs.
    internal func _setOnBeforeAppendForTesting(
        _ hook: (@Sendable () -> Void)?
    ) {
        onBeforeAppendForTesting = hook
    }

    /// TEST-ONLY: installs a hook that simulates a `close(2)`
    /// failure on the export temporary file. A throw projects to
    /// `.operationFailed(.closeTemporaryDestination)`; the
    /// descriptor is best-effort closed so the test does not
    /// leak.
    internal func _setOnCloseTemporaryDestinationForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        onCloseTemporaryDestinationForTesting = hook
    }

    private func ensureHandleNotPendingCloseForTesting(_ handle: FileHandle) throws {
        guard !pendingCloseHandles.contains(where: { $0 === handle }) else {
            throw TestSeamFailure.handleAlreadyPendingClose
        }
    }

    // swiftlint:enable identifier_name
}
