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
    /// serialization contracts are owned by the API design.
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

    /// Writes export bytes to a private temporary destination and
    /// commits them atomically.
    private func writeAndCommitExport(
        parentFD: Int32,
        finalLeaf: String,
        finalURL: URL,
        root: SegmentRoot?,
        segments: [URL]
    ) async throws(FileLogStoreExportError) -> [RemovalBoundaryEntry] {
        // Private temp directory confines partial export bytes during
        // the write phase without process-wide permission mutation.
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
    /// Opens the destination parent directory without following symlinks.
    private func openExportParentDirectory(
        _ url: URL
    ) throws(FileLogStoreExportError) -> Int32 {
        let descriptor: Int32? = url.withUnsafeFileSystemRepresentation { fsPath in
            guard let fsPath else { return nil }
            return Darwin.open(fsPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
            case ENOTDIR, ELOOP:
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
    // Reason: temp-directory create/open cleanup paths each project distinct failures.

    /// Creates and opens a private export temp directory.
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
        let chmodResult = leaf.withCString { cName in
            Darwin.fchmodat(parentFD, cName, 0o700, AT_SYMLINK_NOFOLLOW)
        }
        if chmodResult != 0 {
            let savedErrno = errno
            let unlinkResult = leaf.withCString { cName in
                Darwin.unlinkat(parentFD, cName, AT_REMOVEDIR)
            }
            let unlinkErrno = unlinkResult != 0 ? errno : 0
            var description = "export temp directory mode enforcement failed"
            if unlinkResult != 0 {
                description += "; cleanup unlink failed errno \(unlinkErrno)"
            }
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: description
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
            let unlinkResult = leaf.withCString { cName in
                Darwin.unlinkat(parentFD, cName, AT_REMOVEDIR)
            }
            let unlinkErrno = unlinkResult != 0 ? errno : 0
            var description = "export temp directory open failed"
            if unlinkResult != 0 {
                description += "; cleanup unlink failed errno \(unlinkErrno)"
            }
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: description
                )
            )
        }
        return dirFD
    }

    // swiftlint:enable function_body_length

    /// Creates the export payload temp file inside the private temp directory.
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
                0o600
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
        // `openat` mode is filtered by the process umask, which can mask
        // owner bits (yielding e.g. `0o400` under `0o200`). `fchmod`
        // re-applies the exact `0o600` the writer-private contract
        // requires, descriptor-relative.
        if Darwin.fchmod(descriptor, 0o600) != 0 {
            let savedErrno = errno
            // Unlink before close: while the descriptor is still open
            // the path resolves to the temp object we just created, so
            // the unlink targets exactly that object.
            let unlinkResult = leaf.withCString { cName in
                Darwin.unlinkat(tempDirFD, cName, 0)
            }
            let unlinkErrno = unlinkResult != 0 ? errno : 0
            _ = Darwin.close(descriptor)
            var description = "export temporary permission-bit preservation failed"
            if unlinkResult != 0 {
                description += "; cleanup unlink failed errno \(unlinkErrno)"
            }
            throw .operationFailed(
                operation: .createTemporaryDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: description
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
                // an fd, then project the simulated failure. Cleanup
                // close errno is appended to the description if it
                // fails, but the projected error remains the hook's.
                let cleanupCloseResult = Darwin.close(descriptor)
                let cleanupCloseErrno = cleanupCloseResult != 0 ? errno : 0
                var context = FileSystemErrorContext(from: error)
                if cleanupCloseResult != 0 {
                    context = FileSystemErrorContext(
                        domain: context.domain,
                        code: context.code,
                        description: context.description
                            + "; cleanup close failed errno \(cleanupCloseErrno)"
                    )
                }
                throw .operationFailed(
                    operation: .closeTemporaryDestination,
                    url: url,
                    context: context
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
                    description: "export temporary close failed"
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
        // Commit without overwriting an existing destination.
        let result = tempLeaf.withCString { tmpC in
            finalLeaf.withCString { finalC in
                renameatx_np(tempDirFD, tmpC, parentFD, finalC, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        let savedErrno = errno
        if savedErrno == EEXIST {
            // Destination appeared between pre-check and commit.
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
                    description: "export commit destination re-probe failed"
                )
            )
        }
        throw .operationFailed(
            operation: .commitDestination,
            url: finalURL,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "export commit failed"
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
