import Darwin
import Foundation

extension FileLogStore: ExportableLogStore {
    /// Removes the exported prefix observed by the most recent
    /// successful `exportLogs(to:)` and preserves, byte-for-byte,
    /// all accepted bytes admitted after the successful export
    /// destination commit.
    ///
    /// Serialization semantics: removal holds the nonreentrant
    /// operation boundary while processing the removal boundary.
    /// Concurrent `append`, `flush`, `exportLogs(to:)`, and
    /// `removeExportedLogs()` callers wait until removal releases
    /// that boundary.
    ///
    /// The full removal-boundary, atomicity, and failure-path
    /// contracts are owned by the API design ("Destructive
    /// removal").
    ///
    /// - Throws: ``FileLogStoreRemoveError/noExportedRemovalBoundary``
    ///   when no successful export has captured a boundary in
    ///   this store's lifetime; ``FileLogStoreRemoveError`` for
    ///   any failure during boundary re-validation, segment
    ///   compaction, or unlink.
    public func removeExportedLogs() async throws(FileLogStoreRemoveError) {
        let lease = await operationBoundary.enter()
        // Production-balanced enter/exit always matches, so
        // the result is discarded here; `defer` has no
        // practical throwing path. The mismatch contract is
        // pinned by `OperationBoundary` unit coverage.
        defer { _ = operationBoundary.exit(lease) }
        drainPendingCloseHandles()
        guard let boundary = removalBoundary else {
            throw .noExportedRemovalBoundary
        }
        if boundary.entries.isEmpty {
            removalBoundary = nil
            return
        }

        let removeRoot = try resolveRemovalRoot()
        defer { removeRoot.closeIfOwned() }
        let root = removeRoot.root
        let rootFD = root.rootFD

        try validateRemovalBoundary(boundary.entries, root: root)

        try await executeRemoval(entries: boundary.entries, rootFD: rootFD)

        _ = Darwin.fsync(rootFD)
        removalBoundary = nil
    }

    /// Mutates boundary entries in order and advances the retry
    /// boundary after each completed destructive mutation.
    private func executeRemoval(
        entries: [RemovalBoundaryEntry],
        rootFD: Int32
    ) async throws(FileLogStoreRemoveError) {
        var processed = 0
        do throws(FileLogStoreRemoveError) {
            for entry in entries {
                let postMutation = try await mutateSegmentForRemoval(
                    entry, rootFD: rootFD
                )
                processed += 1
                try runActiveWriterPostMutation(
                    postMutation, entry: entry
                )
            }
        } catch {
            removalBoundary = RemovalBoundary(
                entries: Array(entries.dropFirst(processed))
            )
            throw error
        }
    }

    private func runActiveWriterPostMutation(
        _ postMutation: ActiveWriterPostMutation,
        entry: RemovalBoundaryEntry
    ) throws(FileLogStoreRemoveError) {
        switch postMutation {
        case .noActiveCoordination:
            return
        case .resetWriterOffset:
            // Destructive mutation already completed; invalidate active writer
            // on post-mutation failure so the next append reopens.
            do throws(FileLogStoreRemoveError) {
                try fireBeforeReopenActiveSegmentSeam(url: entry.url)
                try resetActiveWriterOffsetAfterReset(url: entry.url)
            } catch {
                invalidateActiveWriterAfterFailedPostMutation()
                throw error
            }
        case .reopenWriterDescriptor:
            // Destructive mutation already completed; invalidate active writer
            // on post-mutation failure so the next append reopens.
            do throws(FileLogStoreRemoveError) {
                try fireBeforeReopenActiveSegmentSeam(url: entry.url)
                try reopenActiveSegmentAfterCompaction(
                    at: entry.url, sequence: entry.numericSequence
                )
            } catch {
                invalidateActiveWriterAfterFailedPostMutation()
                throw error
            }
        }
    }

    private func fireBeforeReopenActiveSegmentSeam(
        url: URL
    ) throws(FileLogStoreRemoveError) {
        guard let testSeam = onBeforeReopenActiveSegmentForTesting else { return }
        do {
            try testSeam(url)
        } catch {
            throw .operationFailed(
                operation: .reopenActiveSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }
}

// MARK: - Removal root handle

extension FileLogStore {
    private enum RemoveRootHandle {
        case borrowed(SegmentRoot)
        case owned(SegmentRoot)

        var root: SegmentRoot {
            switch self {
            case let .borrowed(root), let .owned(root): root
            }
        }

        /// Releases the owned root descriptor. `SegmentRoot.close()`
        /// is best-effort: the underlying `Darwin.close` result is
        /// already discarded inside `SegmentRoot.close()`, so a
        /// failed close cannot surface here. Borrowed roots stay
        /// owned by the writer and are not touched.
        func closeIfOwned() {
            if case let .owned(root) = self { root.close() }
        }
    }

    private func resolveRemovalRoot() throws(FileLogStoreRemoveError) -> RemoveRootHandle {
        if let held = writerRoot {
            return .borrowed(held)
        }
        let opened: SegmentRoot?
        do throws(InternalReadError) {
            opened = try SegmentRoot.open(directory: configuration.directory)
        } catch {
            // Open-side failure: a real filesystem error (EACCES,
            // ELOOP, ENOTDIR on a path component, etc.) is an
            // operation failure, not a stale-boundary signal.
            throw .operationFailed(
                operation: .validateBoundary,
                url: configuration.directory,
                context: extractFileSystemContext(from: error)
            )
        }
        guard let root = opened else {
            // Open returned no descriptor: the configured root
            // directory is absent. The captured export boundary
            // can no longer reference that on-disk topology, so
            // this is a stale-boundary signal — distinct from
            // the operation-failure branch above.
            throw .removalBoundaryStale(
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOENT),
                    description: "store directory missing during removal"
                )
            )
        }
        return .owned(root)
    }
}

// MARK: - Per-entry dispatch

extension FileLogStore {
    /// Indicates which active-writer post-mutation step the
    /// caller must run after the destructive segment mutation
    /// step has already completed.
    fileprivate enum ActiveWriterPostMutation {
        /// Non-active segment, or active segment that does not
        /// need writer coordination.
        case noActiveCoordination
        /// Active segment was reset after full-prefix removal;
        /// writer position must be reset to the post-removal append
        /// boundary.
        case resetWriterOffset
        /// Active segment was compacted (atomic replace);
        /// writer descriptor must be closed and reopened on
        /// the new path.
        case reopenWriterDescriptor
    }

    /// Performs the destructive segment mutation step: fires
    /// the per-entry seam, re-checks file identity and current
    /// size against the boundary entry (closing the TOCTOU
    /// window between global validation and per-entry
    /// mutation), then unlinks, truncates, or compacts the
    /// segment. Returns the post-mutation kind the caller
    /// must dispatch on; the destructive step has already
    /// completed by then.
    private func mutateSegmentForRemoval(
        _ entry: RemovalBoundaryEntry,
        rootFD: Int32
    ) async throws(FileLogStoreRemoveError) -> ActiveWriterPostMutation {
        try await fireBeforeProcessRemovalEntrySeam(url: entry.url)
        let leaf = entry.url.lastPathComponent
        let (currentSize, currentIdentity) = try readCurrentSegmentStat(
            rootFD: rootFD, leaf: leaf, url: entry.url
        )
        guard currentIdentity == entry.fileIdentity else {
            throw .removalBoundaryStale(
                url: entry.url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "file identity mismatch on per-entry revalidation"
                )
            )
        }
        guard currentSize >= entry.exportedPrefixEnd else {
            throw .removalBoundaryStale(
                url: entry.url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "segment shorter than exported prefix end on per-entry revalidation"
                )
            )
        }
        let isActive = isActiveSegment(at: entry.url)

        if currentSize == entry.exportedPrefixEnd {
            if isActive {
                try resetActiveSegmentAfterFullPrefixRemoval(url: entry.url)
                return .resetWriterOffset
            }
            try unlinkRotatedSegment(
                rootFD: rootFD, url: entry.url, leaf: leaf
            )
            return .noActiveCoordination
        }
        try compactSegment(
            rootFD: rootFD, entry: entry, leaf: leaf
        )
        return isActive ? .reopenWriterDescriptor : .noActiveCoordination
    }

    private func fireBeforeProcessRemovalEntrySeam(
        url: URL
    ) async throws(FileLogStoreRemoveError) {
        guard let testSeam = onBeforeProcessRemovalEntryForTesting else { return }
        do {
            try await testSeam(url)
        } catch {
            throw .operationFailed(
                operation: .validateBoundary,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    private func readCurrentSegmentStat(
        rootFD: Int32, leaf: String, url: URL
    ) throws(FileLogStoreRemoveError) -> (size: UInt64, identity: FileIdentity) {
        let segmentFD = try openSegmentForPerEntryRevalidation(
            rootFD: rootFD, leaf: leaf, url: url
        )
        let handle = FileHandle(fileDescriptor: segmentFD, closeOnDealloc: false)
        var statBuf = stat()
        let fstatResult = Darwin.fstat(segmentFD, &statBuf)
        // Capture errno immediately after fstat; close(2) may
        // set its own errno on failure and would clobber the
        // fstat-failure code.
        let savedFstatErrno = errno
        do {
            try handle.close()
        } catch {
            retainPendingCloseHandle(handle)
        }
        guard fstatResult == 0 else {
            throw .operationFailed(
                operation: .openSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedFstatErrno),
                    description: "removal segment identity read failed"
                )
            )
        }
        let identity = FileIdentity(
            device: statBuf.st_dev,
            inode: statBuf.st_ino
        )
        return (UInt64(statBuf.st_size), identity)
    }

    /// Opens the boundary segment for per-entry revalidation,
    /// classifying `ENOENT` and `ELOOP` as `.removalBoundaryStale`
    /// so a post-validation vanish or symlink swap fails closed
    /// without entering the destructive mutation path.
    private func openSegmentForPerEntryRevalidation(
        rootFD: Int32, leaf: String, url: URL
    ) throws(FileLogStoreRemoveError) -> Int32 {
        let segmentFD = leaf.withCString { cName in
            Darwin.openat(rootFD, cName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if segmentFD >= 0 { return segmentFD }
        let savedErrno = errno
        if savedErrno == ENOENT || savedErrno == ELOOP {
            throw .removalBoundaryStale(
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: savedErrno == ENOENT
                        ? "boundary segment missing on per-entry revalidation"
                        : "boundary segment replaced by symlink on per-entry revalidation"
                )
            )
        }
        throw .operationFailed(
            operation: .openSegment,
            url: url,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "removal segment open failed"
            )
        )
    }
}

// MARK: - Unlink primitive

extension FileLogStore {
    private func unlinkRotatedSegment(
        rootFD: Int32,
        url: URL,
        leaf: String
    ) throws(FileLogStoreRemoveError) {
        let result = leaf.withCString { cName in
            Darwin.unlinkat(rootFD, cName, 0)
        }
        if result != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .unlinkSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "rotated segment unlink failed"
                )
            )
        }
    }
}

// MARK: - InternalReadError context extraction

extension FileLogStore {
    private func extractFileSystemContext(
        from error: InternalReadError
    ) -> FileSystemErrorContext {
        switch error {
        case let .operationFailed(_, _, context):
            context
        case .interiorCorruption:
            FileSystemErrorContext(
                domain: FileSystemErrorContext.packageDomain,
                code: nil,
                description: "interiorCorruption surfaced during removal-root open"
            )
        }
    }
}
