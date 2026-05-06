import Darwin
import Foundation

extension FileLogStore {
    /// Writes a byte-stable export of the recoverable prefix to
    /// `url`. The output file is created atomically and never
    /// overwrites an existing entry at the destination.
    ///
    /// Serialization semantics: export discovery and export
    /// writes execute within this actor-isolated operation.
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
        defer { Darwin.close(parentFD) }
        try validateFinalDestinationAbsent(
            parentFD: parentFD, leaf: finalLeaf, finalURL: url
        )

        try writeAndCommitExport(
            parentFD: parentFD,
            finalLeaf: finalLeaf,
            finalURL: url,
            root: root,
            segments: segments
        )

        // Best-effort directory-entry durability after commit. A
        // failure here does not invalidate the already-visible
        // final file.
        _ = Darwin.fsync(parentFD)
    }

    /// Drives the temp-create / write / sync / close / atomic-commit
    /// sequence and unwinds the temp file on any failure.
    private func writeAndCommitExport(
        parentFD: Int32,
        finalLeaf: String,
        finalURL: URL,
        root: SegmentRoot?,
        segments: [URL]
    ) throws(FileLogStoreExportError) {
        // Bounded temp leaf, independent of `finalLeaf` length, so
        // a long-but-valid final filename does not push the temp
        // entry past `NAME_MAX`.
        let tempLeaf = ".swift-logger-export-\(UUID().uuidString).tmp"
        let tempURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(tempLeaf)
        let tempFD = try createExportTemporary(
            parentFD: parentFD, leaf: tempLeaf, url: tempURL
        )
        var tempFDIsOpen = true
        var committed = false
        defer {
            if tempFDIsOpen { Darwin.close(tempFD) }
            if !committed {
                _ = tempLeaf.withCString { cName in
                    unlinkat(parentFD, cName, 0)
                }
            }
        }

        if let root {
            try writeSegmentsToTemp(
                root: root, segments: segments,
                tempFD: tempFD, tempURL: tempURL
            )
        }
        try fireOnAfterWritingTemporaryBytesSeam(tempURL: tempURL)
        try syncExportTemporary(descriptor: tempFD, url: tempURL)
        // Mark the descriptor consumed before invoking close: a
        // failed `close(2)` leaves the fd in an undefined state and
        // POSIX disallows retry, so the deferred cleanup must not
        // attempt to close it again. Temp unlink still runs because
        // `committed` stays false until the rename succeeds.
        tempFDIsOpen = false
        try closeExportTemporary(descriptor: tempFD, url: tempURL)

        try fireOnBeforeCommitSeam(finalURL: finalURL)

        try commitExportDestination(
            parentFD: parentFD,
            tempLeaf: tempLeaf,
            finalLeaf: finalLeaf,
            finalURL: finalURL
        )
        committed = true
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

// MARK: - Per-segment write

extension FileLogStore {
    private func writeSegmentsToTemp(
        root: SegmentRoot,
        segments: [URL],
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) {
        for segmentURL in segments {
            try writeSegmentToTemp(
                root: root,
                segmentURL: segmentURL,
                tempFD: tempFD,
                tempURL: tempURL
            )
        }
    }

    private func writeSegmentToTemp(
        root: SegmentRoot,
        segmentURL: URL,
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) {
        let handle: FileHandle
        do {
            handle = try root.openSegmentForReading(url: segmentURL)
        } catch {
            throw FileLogStoreExportError(
                projecting: error,
                onto: .openSegment
            )
        }
        defer { try? handle.close() }

        let boundary = try resolveExportBoundary(
            handle: handle, segmentURL: segmentURL
        )
        if boundary == 0 { return }
        try copySegmentBytesToTemp(
            handle: handle,
            boundary: boundary,
            segmentURL: segmentURL,
            tempFD: tempFD,
            tempURL: tempURL
        )
    }

    /// Resolves the recoverable-prefix end of `segmentURL` against
    /// the open `handle` and projects scanner failure onto the
    /// export error surface; interior corruption is rethrown as
    /// `.interiorCorruption`.
    private func resolveExportBoundary(
        handle: FileHandle, segmentURL: URL
    ) throws(FileLogStoreExportError) -> UInt64 {
        let resolution: RecoverablePrefixScanner.BoundaryResolution
        do {
            resolution = try RecoverablePrefixScanner.resolveBoundary(
                handle: handle, segmentURL: segmentURL
            )
        } catch {
            throw FileLogStoreExportError(
                projecting: error, onto: .readSegmentBytes
            )
        }
        switch resolution {
        case let .boundary(value):
            return value
        case let .interiorCorruption(byteOffset, classification):
            throw .interiorCorruption(
                segmentURL: segmentURL,
                byteOffset: byteOffset,
                classification: FileLogStoreExportCorruptionClass(classification)
            )
        }
    }

    /// Streams `[0, boundary)` bytes from `handle` into `tempFD` in
    /// 64 KiB chunks. Unexpected EOF before `boundary` projects to
    /// `.operationFailed(.readSegmentBytes)`.
    private func copySegmentBytesToTemp(
        handle: FileHandle,
        boundary: UInt64,
        segmentURL: URL,
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) {
        do {
            try handle.seek(toOffset: 0)
        } catch {
            throw .operationFailed(
                operation: .readSegmentBytes,
                url: segmentURL,
                context: FileSystemErrorContext(from: error)
            )
        }
        var remaining = boundary
        while remaining > 0 {
            let chunkCap: UInt64 = 65536
            let toRead = Int(min(chunkCap, remaining))
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: toRead)
            } catch {
                throw .operationFailed(
                    operation: .readSegmentBytes,
                    url: segmentURL,
                    context: FileSystemErrorContext(from: error)
                )
            }
            guard let chunk, !chunk.isEmpty else {
                throw .operationFailed(
                    operation: .readSegmentBytes,
                    url: segmentURL,
                    context: FileSystemErrorContext(
                        domain: FileSystemErrorContext.packageDomain,
                        code: nil,
                        description: "unexpectedEOFBeforeBoundary"
                    )
                )
            }
            try writeAllToTemporary(chunk, tempFD: tempFD, tempURL: tempURL)
            remaining -= UInt64(chunk.count)
        }
    }

    private func writeAllToTemporary(
        _ data: Data,
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) {
        let total = data.count
        if total == 0 { return }
        var written = 0
        var failure: FileLogStoreExportError?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while written < total {
                let result = Darwin.write(
                    tempFD,
                    base.advanced(by: written),
                    total - written
                )
                if result < 0 {
                    let savedErrno = errno
                    if savedErrno == EINTR { continue }
                    failure = .operationFailed(
                        operation: .writeTemporaryDestinationBytes,
                        url: tempURL,
                        context: FileSystemErrorContext(
                            domain: NSPOSIXErrorDomain,
                            code: Int(savedErrno),
                            description: "write failed"
                        )
                    )
                    return
                }
                written += result
            }
        }
        if let failure { throw failure }
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
                operation: .validateDestination,
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
                        description: "open(parent O_DIRECTORY) failed"
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
                    description: "fstatat(final) failed"
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

    private func createExportTemporary(
        parentFD: Int32,
        leaf: String,
        url: URL
    ) throws(FileLogStoreExportError) -> Int32 {
        let mode: mode_t = 0o600
        let descriptor = leaf.withCString { cName in
            Darwin.openat(
                parentFD,
                cName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode
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
                    description: "openat(temp O_CREAT|O_EXCL|O_NOFOLLOW) failed"
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
                    description: "fsync(temp) failed"
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
        parentFD: Int32,
        tempLeaf: String,
        finalLeaf: String,
        finalURL: URL
    ) throws(FileLogStoreExportError) {
        let result = tempLeaf.withCString { tmpC in
            finalLeaf.withCString { finalC in
                renameatx_np(parentFD, tmpC, parentFD, finalC, UInt32(RENAME_EXCL))
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
    fileprivate init(
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
