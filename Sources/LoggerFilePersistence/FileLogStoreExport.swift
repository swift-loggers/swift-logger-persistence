import Darwin
import Foundation

extension FileLogStore {
    /// Writes a byte-stable export of the recoverable prefix to
    /// `url`. The output file is created atomically and never
    /// overwrites an existing entry at the destination.
    ///
    /// Serialization semantics: export discovery and export
    /// writes execute while holding the nonreentrant operation
    /// boundary. Concurrent append, flush, export, and removal
    /// callers wait until the export operation releases that
    /// boundary.
    /// Accepted bytes are preserved byte-for-byte from each
    /// segment's recoverable prefix in accepted ordering.
    /// (`.never` → `log.ndjson`; `.bySize` → rotated segments
    /// ascending by numeric sequence).
    /// Duplicate `sequence` values are preserved.
    ///
    /// The full atomic-commit, failure-path, and export
    /// serialization contracts are owned by `Docs/APIDesign.md`
    /// ("Byte-stable export").
    ///
    /// - Throws: ``FileLogStoreExportError`` for any failure on
    ///   discovery, segment read, destination create, write,
    ///   sync, close, or commit.
    public func exportLogs(
        to url: URL
    ) async throws(FileLogStoreExportError) {
        let lease = await operationBoundary.enter()
        // Production-balanced enter/exit always matches, so
        // the result is discarded here; `defer` has no
        // practical throwing path. The mismatch contract is
        // pinned by `OperationBoundary` unit coverage.
        defer { _ = operationBoundary.exit(lease) }
        try validateExportDestinationURL(url)
        drainPendingCloseHandles()
        let exportRoot = try resolveExportRoot()
        defer { exportRoot.closeIfOwned() }
        let root = exportRoot.root
        let segments = try root.map(discoverExportSegments) ?? []

        let parentURL = url.deletingLastPathComponent()
        try validateExportParentURL(parentURL, finalURL: url)
        let finalLeaf = url.lastPathComponent
        let parentFD = try openExportParentDirectory(parentURL)
        defer { _ = Darwin.close(parentFD) }
        try validateFinalDestinationAbsent(
            parentFD: parentFD, leaf: finalLeaf, finalURL: url
        )

        let boundaryEntries = try await writeAndCommitExport(
            parentFD: parentFD,
            finalLeaf: finalLeaf,
            finalURL: url,
            root: root,
            segments: segments
        )
        // Capture the in-memory removal boundary only after the
        // final destination commit has succeeded. A failed export
        // must not advance or create a removal boundary.
        removalBoundary = RemovalBoundary(entries: boundaryEntries)

        // Best-effort directory-entry durability after commit. A
        // failure here does not invalidate the already-visible
        // final file.
        _ = Darwin.fsync(parentFD)
    }

    /// Drives the temp-create / write / sync / close / atomic-commit
    /// sequence and unwinds the temp file on any failure.
    /// Returns the per-segment removal-boundary entries captured
    /// during the write phase; the caller stores them on actor
    /// state only after a successful commit.
    private func writeAndCommitExport(
        parentFD: Int32,
        finalLeaf: String,
        finalURL: URL,
        root: SegmentRoot?,
        segments: [URL]
    ) async throws(FileLogStoreExportError) -> [RemovalBoundaryEntry] {
        // Private temp directory in the destination parent
        // (mode 0o700) confines partial export bytes during the
        // write phase: the file inside is not reachable by other
        // principals because the directory itself denies them
        // search/read access. The payload file is then created
        // with mode 0o666, which the platform umask filters into
        // the final-destination permission bits — no library-
        // level `umask(0)` lookup or process-wide umask side
        // effect is needed.
        let tempDirLeaf = ".swift-logger-export-\(UUID().uuidString).tmpdir"
        let tempLeaf = "export.tmp"
        let tempDirURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(tempDirLeaf)
        let tempURL = tempDirURL.appendingPathComponent(tempLeaf)

        let tempDirFD = try createExportTempDirectory(
            parentFD: parentFD, leaf: tempDirLeaf, url: tempDirURL
        )
        var committed = false
        defer {
            if !committed {
                // Failure path: best-effort unlink of the temp
                // file inside the private dir, then rmdir of the
                // dir itself. Cleanup failures here do not
                // change the export error already in flight.
                _ = tempLeaf.withCString {
                    Darwin.unlinkat(tempDirFD, $0, 0)
                }
            }
            // Always remove the private temp dir: empty after a
            // successful commit (renameat moved the file out)
            // and emptied above on the failure path.
            _ = tempDirLeaf.withCString {
                Darwin.unlinkat(parentFD, $0, AT_REMOVEDIR)
            }
            _ = Darwin.close(tempDirFD)
        }

        let tempFD = try createExportTemporary(
            tempDirFD: tempDirFD, leaf: tempLeaf, url: tempURL
        )
        var tempFDIsOpen = true
        defer {
            if tempFDIsOpen { _ = Darwin.close(tempFD) }
        }

        var boundaryEntries: [RemovalBoundaryEntry] = []
        if let root {
            boundaryEntries = try writeSegmentsToTemp(
                root: root, segments: segments,
                tempFD: tempFD, tempURL: tempURL
            )
        }
        try await fireOnAfterWritingTemporaryBytesSeam(tempURL: tempURL)
        try syncExportTemporary(descriptor: tempFD, url: tempURL)
        // Mark the export temporary's raw fd as consumed before
        // invoking close. The `pendingCloseHandles` queue
        // retains owning `FileHandle`s for deferred close; the
        // export temporary is a raw descriptor closed explicitly
        // here. After a failed `close(2)` the fd is in an
        // undefined state and must not be closed a second time,
        // so the deferred cleanup skips it. Temp unlink still
        // runs because `committed` stays false until the rename
        // succeeds.
        tempFDIsOpen = false
        try closeExportTemporary(descriptor: tempFD, url: tempURL)

        try fireOnBeforeCommitSeam(finalURL: finalURL)

        try commitExportDestination(
            tempDirFD: tempDirFD,
            tempLeaf: tempLeaf,
            parentFD: parentFD,
            finalLeaf: finalLeaf,
            finalURL: finalURL
        )
        committed = true
        return boundaryEntries
    }
}

// MARK: - Export root helpers

extension FileLogStore {
    fileprivate enum ExportRootHandle {
        case borrowed(SegmentRoot)
        case owned(SegmentRoot)
        case empty

        var root: SegmentRoot? {
            switch self {
            case let .borrowed(root), let .owned(root): root
            case .empty: nil
            }
        }

        func closeIfOwned() {
            if case let .owned(root) = self { root.close() }
        }
    }

    private func resolveExportRoot() throws(FileLogStoreExportError) -> ExportRootHandle {
        if let held = writerRoot {
            return .borrowed(held)
        }
        let opened: SegmentRoot?
        do throws(InternalReadError) {
            opened = try SegmentRoot.open(directory: configuration.directory)
        } catch {
            throw FileLogStoreExportError(
                projecting: error,
                onto: .enumerateSegments
            )
        }
        if let opened {
            return .owned(opened)
        }
        return .empty
    }

    private func discoverExportSegments(
        root: SegmentRoot
    ) throws(FileLogStoreExportError) -> [URL] {
        do throws(InternalReadError) {
            switch configuration.rotation.kind {
            case .never:
                if let url = try root.unrotatedSegmentURLIfRegular() {
                    return [url]
                }
                return []
            case .bySize:
                return try root.enumerateRotatedSegments().map(\.url)
            }
        } catch {
            throw FileLogStoreExportError(
                projecting: error,
                onto: .enumerateSegments
            )
        }
    }
}

// MARK: - Destination open / commit

extension FileLogStore {
    private func openExportParentDirectory(
        _ url: URL
    ) throws(FileLogStoreExportError) -> Int32 {
        let descriptor: Int32? = url.withUnsafeFileSystemRepresentation { fsPath in
            guard let fsPath else { return nil }
            return Darwin.open(fsPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard let descriptor else {
            throw .operationFailed(
                operation: .openDestinationParent,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "destination parent has no filesystem representation"
                )
            )
        }
        if descriptor < 0 {
            let savedErrno = errno
            switch savedErrno {
            case ENOENT:
                throw .invalidDestination(reason: .parentDirectoryAbsent)
            case ENOTDIR:
                throw .invalidDestination(reason: .parentDirectoryInvalid)
            default:
                throw .operationFailed(
                    operation: .openDestinationParent,
                    url: url,
                    context: FileSystemErrorContext(
                        domain: NSPOSIXErrorDomain,
                        code: Int(savedErrno),
                        description: "destination parent open failed"
                    )
                )
            }
        }
        return descriptor
    }

    private func validateFinalDestinationAbsent(
        parentFD: Int32,
        leaf: String,
        finalURL: URL
    ) throws(FileLogStoreExportError) {
        var statBuf = stat()
        let result = leaf.withCString { cName in
            fstatat(parentFD, cName, &statBuf, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let savedErrno = errno
            if savedErrno == ENOENT { return }
            throw .operationFailed(
                operation: .validateDestination,
                url: finalURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "final destination validation failed"
                )
            )
        }
        throw .invalidDestination(reason: classifyExistingDestination(statBuf))
    }

    private func classifyExistingDestination(
        _ statBuf: stat
    ) -> FileLogStoreExportInvalidDestinationReason {
        switch statBuf.st_mode & S_IFMT {
        case S_IFREG: .alreadyExistsAsRegularFile
        case S_IFLNK: .alreadyExistsAsSymlink
        case S_IFDIR: .alreadyExistsAsDirectory
        default: .alreadyExistsAsNonRegular
        }
    }

    // swiftlint:disable function_body_length
    // Reason: Three failure points (mkdirat / fchmodat / openat) each carry their own cleanup-then-throw projection so each half-created private temp directory failure path attempts cleanup before projecting its error.

    /// Creates a private (`0o700`) temp directory in the
    /// destination parent and returns an opened descriptor.
    /// The directory confines the export's payload temp file so
    /// partial bytes are not readable by other principals
    /// during the write phase. Failure attempts to clean up
    /// the half-created directory before throwing; the cleanup
    /// is filesystem best-effort, not an absolute guarantee.
    private func createExportTempDirectory(
        parentFD: Int32,
        leaf: String,
        url: URL
    ) throws(FileLogStoreExportError) -> Int32 {
        let mkdirResult = leaf.withCString { cName in
            Darwin.mkdirat(parentFD, cName, 0o700)
        }
        if mkdirResult != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "export temp directory create failed"
                )
            )
        }
        // Enforce private temp directory permissions explicitly.
        // `mkdirat`'s mode is filtered by the platform umask, so
        // a strict umask (e.g. `077` masking group/other bits
        // already covered by `0o700` is fine, but a hostile
        // umask masking owner bits would weaken the private
        // contract). `fchmodat` re-applies the exact mode bits
        // the private-temp-dir invariant requires.
        let chmodResult = leaf.withCString { cName in
            // `AT_SYMLINK_NOFOLLOW` so a symlink racing into
            // place between `mkdirat` and `fchmodat` is not
            // followed; the subsequent `openat(... O_NOFOLLOW
            // | O_DIRECTORY)` is the canonical defender, but
            // keeping the chmod no-follow closes the small
            // intervening window.
            Darwin.fchmodat(parentFD, cName, 0o700, AT_SYMLINK_NOFOLLOW)
        }
        if chmodResult != 0 {
            let savedErrno = errno
            _ = leaf.withCString {
                Darwin.unlinkat(parentFD, $0, AT_REMOVEDIR)
            }
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "export temp directory mode enforcement failed"
                )
            )
        }
        let dirFD = leaf.withCString { cName in
            Darwin.openat(
                parentFD, cName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if dirFD < 0 {
            let savedErrno = errno
            // Best-effort cleanup of the just-created directory
            // before surfacing the open failure.
            _ = leaf.withCString {
                Darwin.unlinkat(parentFD, $0, AT_REMOVEDIR)
            }
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "export temp directory open failed"
                )
            )
        }
        return dirFD
    }

    // swiftlint:enable function_body_length

    /// Creates the export payload temp file inside the private
    /// temp directory. The file is created with mode `0o666` so
    /// the platform umask filters it into the final-destination
    /// permission bits; the surrounding `0o700` directory
    /// already prevents other principals from reading the
    /// partial bytes during the write phase.
    private func createExportTemporary(
        tempDirFD: Int32,
        leaf: String,
        url: URL
    ) throws(FileLogStoreExportError) -> Int32 {
        let descriptor = leaf.withCString { cName in
            Darwin.openat(
                tempDirFD,
                cName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o666
            )
        }
        if descriptor < 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "export temporary create failed"
                )
            )
        }
        return descriptor
    }

    private func syncExportTemporary(
        descriptor: Int32,
        url: URL
    ) throws(FileLogStoreExportError) {
        if Darwin.fsync(descriptor) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .syncTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "export temporary sync failed"
                )
            )
        }
    }

    private func closeExportTemporary(
        descriptor: Int32,
        url: URL
    ) throws(FileLogStoreExportError) {
        if let hook = onCloseTemporaryDestinationForTesting {
            do {
                try hook()
            } catch {
                // Hook simulates a close failure. Best-effort
                // close the descriptor so the test does not leak
                // an fd, then project the simulated failure.
                _ = Darwin.close(descriptor)
                throw .operationFailed(
                    operation: .closeTemporaryDestination,
                    url: url,
                    context: FileSystemErrorContext(from: error)
                )
            }
        }
        if Darwin.close(descriptor) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .closeTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "close(temp) failed"
                )
            )
        }
    }

    private func commitExportDestination(
        tempDirFD: Int32,
        tempLeaf: String,
        parentFD: Int32,
        finalLeaf: String,
        finalURL: URL
    ) throws(FileLogStoreExportError) {
        // Cross-directory atomic rename: temp file in the
        // private temp dir → final leaf in the destination
        // parent. The private dir is removed by the caller's
        // `defer` after this returns (or on the failure path).
        let result = tempLeaf.withCString { tmpC in
            finalLeaf.withCString { finalC in
                renameatx_np(tempDirFD, tmpC, parentFD, finalC, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        let savedErrno = errno
        if savedErrno == EEXIST {
            // Final materialized between pre-check and commit.
            // Re-probe topology so the projected reason matches
            // what is now at the destination. If the probe itself
            // fails (race removed the entry, EACCES, etc.) project
            // the probe error rather than fabricating a topology
            // we did not actually observe.
            var statBuf = stat()
            let probe = finalLeaf.withCString { cName in
                fstatat(parentFD, cName, &statBuf, AT_SYMLINK_NOFOLLOW)
            }
            if probe == 0 {
                throw .invalidDestination(
                    reason: classifyExistingDestination(statBuf)
                )
            }
            let probeErrno = errno
            throw .operationFailed(
                operation: .commitDestination,
                url: finalURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(probeErrno),
                    description: "renameatx_np EEXIST; re-probe failed"
                )
            )
        }
        throw .operationFailed(
            operation: .commitDestination,
            url: finalURL,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "renameatx_np(RENAME_EXCL) failed"
            )
        )
    }
}

// MARK: - Internal-error → export-error projection

extension FileLogStoreExportError {
    init(
        projecting error: InternalReadError,
        onto operation: FileLogStoreExportOperation
    ) {
        switch error {
        case let .operationFailed(_, url, context):
            self = .operationFailed(
                operation: operation,
                url: url,
                context: context
            )
        case let .interiorCorruption(segmentURL, byteOffset, classification):
            self = .interiorCorruption(
                segmentURL: segmentURL,
                byteOffset: byteOffset,
                classification: FileLogStoreExportCorruptionClass(classification)
            )
        }
    }
}
