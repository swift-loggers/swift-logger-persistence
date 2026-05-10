// swiftlint:disable file_length - Active-segment and pending-close mutators must live in the same file as the `private` storage so cross-file paths cannot bypass the actor's narrow operation-level contract.
import Darwin
import Foundation
import LoggerPersistence

/// File-backed `PersistentLogStore`. Each `append(_:)` admits one
/// canonical LF-terminated NDJSON envelope line into a segment file.
///
/// Wire format is owned by the file-format specification. Segment
/// topology (naming, rotation boundaries, retention) is a policy
/// contract, not portable wire format. The actor serializes
/// file-handle I/O. Producer-owned sequence metadata is preserved
/// unchanged by the store.
public actor FileLogStore: PersistentLogStore {
    /// Encoded NDJSON line byte cap per the file-format
    /// specification ("Payload and Bounds"): an envelope line,
    /// including base64 payload, JSON punctuation, and trailing
    /// LF, must not exceed 2 MiB.
    public static let maxEncodedLineBytes = 2_097_152

    /// Module-internal so the export extension in a sibling file
    /// can resolve the configured root path without exposing
    /// configuration as public API.
    internal let configuration: Configuration
    private let lineEncoder = CanonicalEnvelopeLineEncoder()
    /// Active writable segment. `private` so cross-file remove,
    /// export, and test-seam paths must go through the narrow
    /// operation-level helpers defined on this actor (e.g.
    /// ``resetActiveSegmentAfterFullPrefixRemoval(url:)``,
    /// ``reopenActiveSegmentAfterCompaction(at:sequence:)``,
    /// ``invalidateActiveWriterAfterFailedPostMutation()``,
    /// ``isActiveSegment(at:)``) rather than mutate raw state.
    private var activeSegment: ActiveSegment?
    /// Held configured-root descriptor. Opened once on the first
    /// admit and reused for every subsequent segment open / rotation
    /// so a path-component swap of `configuration.directory` after
    /// the descriptor is held cannot redirect writes to a different
    /// real directory. Module-internal so the export extension in a
    /// sibling file can borrow it under actor isolation.
    internal var writerRoot: SegmentRoot?
    /// Handles whose `close()` failed during a rotation transition.
    /// Retained on the actor so a transient close failure does not
    /// orphan a file descriptor; drained on each later admit/flush
    /// boundary and on `deinit` as a best-effort retry. `private`
    /// so cross-file callers route appends through
    /// ``retainPendingCloseHandle(_:)`` rather than mutate the
    /// queue directly.
    private var pendingCloseHandles: [FileHandle] = []
    /// In-memory removal boundary captured by the most recent
    /// successful `exportLogs(to:)`. `nil` means no removable
    /// prefix exists; `removeExportedLogs()` then fails with
    /// `.noExportedRemovalBoundary`. Module-internal so the
    /// export and remove extensions in sibling files can read
    /// and update it under actor isolation.
    internal var removalBoundary: RemovalBoundary?
    /// Nonreentrant boundary held across every `await` inside
    /// `append`, `flush`, `exportLogs(to:)`, and
    /// `removeExportedLogs()`. Closes the actor-reentrancy
    /// window so a body suspension (including an awaiting test
    /// seam) cannot let another operation interleave the
    /// in-flight one's critical section. Module-internal so
    /// the export and remove extensions in sibling files can
    /// hold it under actor isolation.
    internal let operationBoundary = OperationBoundary()

    /// TEST-ONLY: installs a seam before writable segment open.
    /// Thrown errors project to `.openWritableSegment`.
    internal var onBeforeOpenWritableSegmentForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY: installs a seam before writer-root open.
    /// Thrown errors project to `.openWritableSegment`.
    internal var onBeforeWriterRootOpenForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY: installs a seam before export temp fsync.
    /// Thrown errors project to `.writeTemporaryDestinationBytes`.
    internal var onAfterWritingTemporaryBytesForTesting: (@Sendable () async throws -> Void)?

    /// TEST-ONLY: installs a seam before export commit.
    /// Thrown errors project to `.commitDestination`.
    internal var onBeforeCommitForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY: installs a seam after admitted append bytes reach storage.
    internal var onAfterAppendForTesting: (@Sendable () -> Void)?

    /// TEST-ONLY: installs a seam after append acquires the operation boundary.
    internal var onBeforeAppendForTesting: (@Sendable () -> Void)?

    /// TEST-ONLY: installs a seam before export temp close.
    /// Thrown errors project to `.closeTemporaryDestination`.
    internal var onCloseTemporaryDestinationForTesting: (@Sendable () throws -> Void)?

    /// TEST-ONLY: installs a seam before each per-entry removal mutation.
    /// Thrown errors project to `.validateBoundary`.
    internal var onBeforeProcessRemovalEntryForTesting: (@Sendable (URL) async throws -> Void)?

    /// TEST-ONLY: installs a seam before active-writer reopen after removal mutation.
    /// Thrown errors project to `.reopenActiveSegment`.
    internal var onBeforeReopenActiveSegmentForTesting: (@Sendable (URL) throws -> Void)?

    /// TEST-ONLY: installs a seam before compaction opens a segment for reading.
    /// Thrown errors project to `.openSegment`.
    internal var onBeforeOpenCompactionReadForTesting: (@Sendable (URL) throws -> Void)?

    /// TEST-ONLY: installs a seam before compaction's pre-replace boundary revalidation.
    /// Thrown errors project to `.validateBoundary`.
    internal var onBeforePreReplaceRevalidateForTesting: (@Sendable (URL) throws -> Void)?

    /// TEST-ONLY: rotated-topology classification override.
    internal var rotatedTopologyOverrideForTesting: (@Sendable () -> InternalReadError?)?

    /// TEST-ONLY: installs a seam before each retention segment deletion.
    /// Thrown errors project to `.enforceRetention`.
    internal var onBeforeRetentionUnlinkForTesting: (@Sendable (URL) throws -> Void)?

    /// TEST-ONLY: installs a seam between successful leaf `mkdir(2)`
    /// and the umask-independent permission preservation step.
    /// Thrown errors project to `.createDirectory`.
    internal var onBeforeDirectoryChmodForTesting: (@Sendable (URL) throws -> Void)?

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
    /// segments per the file-format specification ("Append
    /// Rotation Interaction").
    ///
    /// - Throws: ``FileLogStoreError`` on file-system failure,
    ///   pre-admission validation failure, or implementation
    ///   invariant violation. Validation failures and encoding
    ///   failures occur before any storage mutation; rejected
    ///   envelopes never extend the recoverable prefix.
    ///
    ///   If retention deletion fails after admitted bytes are written,
    ///   `append(_:)` throws `.operationFailed(.enforceRetention, ...)`.
    ///   In that case the triggering envelope remains accepted; callers
    ///   must not retry it as if admission failed.
    public func append(
        _ envelope: PersistentLogEnvelope
    ) async throws(FileLogStoreError) {
        let lease = await operationBoundary.enter()
        // Balanced enter/exit is covered by OperationBoundary tests.
        defer { _ = operationBoundary.exit(lease) }
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
            // Write failure leaves the active segment state undefined; the next
            // admit must reopen through recoverable-prefix trimming.
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
        // Retention runs inside the append boundary after admission.
        try enforceRetention()
        onAfterAppendForTesting?()
    }

    /// Verifies the encoded line ends with the canonical trailing
    /// LF per the file-format specification. Safe to run before
    /// the encoded-line size cap.
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
        let lease = await operationBoundary.enter()
        // Balanced enter/exit is covered by OperationBoundary tests.
        defer { _ = operationBoundary.exit(lease) }
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
        // Activate next segment before closing the previous handle.
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
        // Close or retain the handle until ownership transfers.
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

    /// Returns the rotated-segment URL for `sequence` using the
    /// production-owned default minimum decimal width.
    private func rotatedSegmentURL(sequence: UInt64) -> URL {
        SegmentEnumeration.rotatedSegmentURL(
            in: configuration.directory,
            sequence: sequence
        )
    }

    /// Positions `handle` at the recoverable-prefix boundary,
    /// truncating trailing partial bytes and failing closed on
    /// interior corruption.
    private func trimTrailingSuffixAndPosition(
        handle: FileHandle,
        segmentURL: URL
    ) throws(FileLogStoreError) {
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
                    description: "interior corruption"
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
                    description: "configured directory absent after create"
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
    ///
    /// Newly-created directories are owner-only (`0o700`),
    /// umask-independent, so an admitted log stream is private by
    /// default even under a restrictive process umask. A
    /// pre-existing directory is left as-is — this call never
    /// tightens permissions on a directory it did not create. The
    /// newly-created decision comes from the atomic `mkdir(2)`
    /// EEXIST signal, so a foreign actor racing the leaf into
    /// place cannot trigger a permission tighten.
    private func createDirectoryIfNeeded(
        fileManager: FileManager
    ) throws(FileLogStoreError) -> DirectoryIdentity {
        let directoryPath = configuration.directory.path
        try createDirectoryParentsIfNeeded(fileManager: fileManager)
        let leafNewlyCreated = try createLeafDirectoryAtomically(path: directoryPath)
        if leafNewlyCreated {
            try fireBeforeDirectoryPermissionPreservationSeam(
                url: configuration.directory
            )
            try applyOwnerOnlyPermissions(path: directoryPath)
        }
        return try captureDirectoryIdentity(path: directoryPath)
    }

    private func createDirectoryParentsIfNeeded(
        fileManager: FileManager
    ) throws(FileLogStoreError) {
        let parentURL = configuration.directory.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Returns `true` when this call created the leaf, `false` when
    /// the leaf already existed. The newly-created signal comes
    /// from the atomic `mkdir(2)` EEXIST return so it cannot drift
    /// against a concurrent foreign creator.
    private func createLeafDirectoryAtomically(
        path: String
    ) throws(FileLogStoreError) -> Bool {
        let mkdirResult = path.withCString { cPath in
            Darwin.mkdir(cPath, 0o700)
        }
        if mkdirResult == 0 {
            return true
        }
        let mkdirErrno = errno
        if mkdirErrno == EEXIST {
            return false
        }
        throw .operationFailed(
            operation: .createDirectory,
            url: configuration.directory,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(mkdirErrno),
                description: "directory create failed"
            )
        )
    }

    private func fireBeforeDirectoryPermissionPreservationSeam(
        url: URL
    ) throws(FileLogStoreError) {
        guard let hook = onBeforeDirectoryChmodForTesting else { return }
        do {
            try hook(url)
        } catch {
            throw .operationFailed(
                operation: .createDirectory,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Re-applies `0o700` on a newly-created leaf so the
    /// writer-private contract holds regardless of process umask.
    private func applyOwnerOnlyPermissions(
        path: String
    ) throws(FileLogStoreError) {
        let chmodResult = path.withCString { cPath in
            Darwin.fchmodat(AT_FDCWD, cPath, 0o700, AT_SYMLINK_NOFOLLOW)
        }
        if chmodResult != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .createDirectory,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "directory permission-bit preservation failed"
                )
            )
        }
    }

    private func captureDirectoryIdentity(
        path: String
    ) throws(FileLogStoreError) -> DirectoryIdentity {
        var statBuf = stat()
        let result = path.withCString { cPath in
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
                    description: "directory metadata read failed"
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
    /// actor isolation.
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
    internal struct ActiveSegment {
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

        /// Segment retention policy enforced after each successful
        /// append admission.
        public var retention: RetentionPolicy

        public init(directory: URL) {
            self.directory = directory
            rotation = .never
            retention = .unlimited
        }

        public init(directory: URL, rotation: RotationPolicy) {
            self.directory = directory
            self.rotation = rotation
            retention = .unlimited
        }

        public init(
            directory: URL,
            rotation: RotationPolicy,
            retention: RetentionPolicy
        ) {
            self.directory = directory
            self.rotation = rotation
            self.retention = retention
        }
    }
}

// MARK: - Pending-close discipline

extension FileLogStore {
    /// Retains `handle` for deferred close and best-effort
    /// retry at the next admit/flush/export/remove boundary.
    /// Cross-file paths that observe a `close()` failure must
    /// route through this entry point so the deferred-close
    /// queue is mutated only via the actor's narrow contract.
    internal func retainPendingCloseHandle(_ handle: FileHandle) {
        pendingCloseHandles.append(handle)
    }
}

// MARK: - Active-segment narrow operations

extension FileLogStore {
    /// Returns whether the active segment's URL matches `url`.
    /// Lets removal pathways branch on active vs. rotated
    /// segments without exposing raw active-segment state.
    internal func isActiveSegment(at url: URL) -> Bool {
        activeSegment?.url == url
    }

    /// Destructive step of the active fully-exported reset
    /// path: resets the active writer's segment so it preserves
    /// no accepted bytes before the removal boundary, and
    /// updates the `size` invariant to match the new on-disk
    /// state. Writer-offset alignment is a separate step
    /// (``resetActiveWriterOffsetAfterReset``) so the
    /// boundary tail can advance past the entry once the
    /// destructive step completes.
    internal func resetActiveSegmentAfterFullPrefixRemoval(
        url: URL
    ) throws(FileLogStoreRemoveError) {
        guard let active = activeSegment, active.url == url else {
            return
        }
        let descriptor = active.handle.fileDescriptor
        if Darwin.ftruncate(descriptor, 0) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "active segment reset failed"
                )
            )
        }
        // Even if the subsequent writer-offset reset fails,
        // the actor's `size` invariant must reflect the
        // reset on-disk state.
        activeSegment = ActiveSegment(
            handle: active.handle,
            url: active.url,
            sequence: active.sequence,
            size: 0
        )
    }

    /// Writer-offset-alignment step that pairs with the
    /// active-segment reset. Repositions the writer FD to the
    /// active-segment reset append boundary after the active
    /// segment was reset; failure here surfaces to the caller
    /// while the destructive step has already advanced the
    /// boundary tail past the entry.
    internal func resetActiveWriterOffsetAfterReset(
        url: URL
    ) throws(FileLogStoreRemoveError) {
        guard let active = activeSegment, active.url == url else {
            return
        }
        let descriptor = active.handle.fileDescriptor
        if Darwin.lseek(descriptor, 0, SEEK_SET) < 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "active writer offset reset failed"
                )
            )
        }
    }

    /// Invalidates the active writer after a post-mutation
    /// failure. Covers both destructive paths:
    ///
    /// - **active-segment reset:** the segment was truncated on
    ///   disk but the writer's offset still points past the
    ///   reset boundary; a subsequent append could resume from
    ///   the stale offset and create a sparse gap.
    /// - **compaction atomic replacement:** the segment at the
    ///   boundary path was replaced by `renameat`, so the
    ///   writer's open handle now references a detached inode;
    ///   a subsequent append could land in the unlinked-but-
    ///   still-referenced inode instead of the on-disk
    ///   compacted segment.
    ///
    /// Drops the active segment and routes the handle through
    /// the deferred-close discipline so the next append re-opens
    /// fresh on the current on-disk path.
    internal func invalidateActiveWriterAfterFailedPostMutation() {
        guard let stale = activeSegment else { return }
        activeSegment = nil
        do {
            try stale.handle.close()
        } catch {
            pendingCloseHandles.append(stale.handle)
        }
    }

    /// Closes the stale active writer handle, which referenced
    /// the old on-disk segment after atomic replacement,
    /// and reopens the writer descriptor on the compacted
    /// path, positioning at the compacted segment's end.
    internal func reopenActiveSegmentAfterCompaction(
        at url: URL,
        sequence: UInt64?
    ) throws(FileLogStoreRemoveError) {
        guard let active = activeSegment, active.url == url else {
            return
        }
        let oldHandle = active.handle
        activeSegment = nil
        closeOrDeferHandle(oldHandle)
        guard let root = writerRoot else {
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "writerRoot missing during reopen"
                )
            )
        }
        let newHandle: FileHandle
        do {
            newHandle = try root.openSegmentForWriting(url: url)
        } catch {
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
        let position: UInt64
        do {
            position = try newHandle.seekToEnd()
        } catch {
            // Preserve undefined-state close handling through the
            // deferred-close queue.
            closeOrDeferHandle(newHandle)
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
        activeSegment = ActiveSegment(
            handle: newHandle,
            url: url,
            sequence: sequence,
            size: position
        )
    }

    /// Closes the handle synchronously, or enqueues it on the
    /// pending-close queue if synchronous close fails so a later
    /// drain can retry rather than leaking the descriptor.
    private func closeOrDeferHandle(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            pendingCloseHandles.append(handle)
        }
    }
}

// MARK: - TEST-ONLY active-segment / pending-close mutators

//
// These live alongside the actor's storage so the storage can
// stay `private`. Sibling test-seam files install closures into
// `var on…ForTesting` properties; the helpers below are the
// only narrow mutators that observe or modify the private
// `activeSegment` / `pendingCloseHandles` state.

extension FileLogStore {
    // swiftlint:disable identifier_name

    /// TEST-ONLY: closes the active handle and clears `activeSegment`.
    /// Failed close is retained for retry.
    /// Invariant: active handle must not already be pending close.
    internal func _forceCloseActiveHandleForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        try _ensureHandleNotPendingCloseForTesting(active.handle)
        do {
            try active.handle.close()
            activeSegment = nil
        } catch {
            pendingCloseHandles.append(active.handle)
            activeSegment = nil
            throw error
        }
    }

    /// TEST-ONLY: leaves `activeSegment` pointing at a closed
    /// handle. Invariant: active handle must not already be
    /// pending close.
    internal func _forceCloseActiveHandleLeavingInvalidReferenceForTesting() throws {
        guard let active = activeSegment else {
            throw TestSeamFailure.noActiveSegment
        }
        let handle = active.handle
        try _ensureHandleNotPendingCloseForTesting(handle)
        try handle.close()
        activeSegment = ActiveSegment(
            handle: handle,
            url: active.url,
            sequence: active.sequence,
            size: active.size
        )
    }

    /// TEST-ONLY: injects a handle into the pending-close retry queue.
    /// Invariant: handle must not already be pending close.
    internal func _injectPendingCloseHandleForTesting(_ handle: FileHandle) throws {
        try _ensureHandleNotPendingCloseForTesting(handle)
        pendingCloseHandles.append(handle)
    }

    internal var _pendingCloseHandleCountForTesting: Int {
        pendingCloseHandles.count
    }

    private func _ensureHandleNotPendingCloseForTesting(_ handle: FileHandle) throws {
        guard !pendingCloseHandles.contains(where: { $0 === handle }) else {
            throw TestSeamFailure.handleAlreadyPendingClose
        }
    }

    // swiftlint:enable identifier_name
}
