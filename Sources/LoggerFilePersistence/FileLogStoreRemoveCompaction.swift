import Darwin
import Foundation

// MARK: - Boundary re-validation

extension FileLogStore {
    /// Re-validates every boundary entry against current
    /// on-disk topology BEFORE any mutation runs. Detects
    /// ambiguous rotated topology (duplicate sequences) for
    /// `.bySize` stores, then per-entry identity and size
    /// mismatches. All mismatches surface as
    /// `.removalBoundaryStale`; the disk is not touched.
    func validateRemovalBoundary(
        _ entries: [RemovalBoundaryEntry],
        root: SegmentRoot
    ) throws(FileLogStoreRemoveError) {
        try assertUnambiguousRotatedTopology(root: root)
        for entry in entries {
            try revalidateEntry(entry, rootFD: root.rootFD)
        }
    }

    private func assertUnambiguousRotatedTopology(
        root: SegmentRoot
    ) throws(FileLogStoreRemoveError) {
        guard case .bySize = configuration.rotation.kind else { return }
        do throws(InternalReadError) {
            if let injected = rotatedTopologyOverrideForTesting?() {
                throw injected
            }
            _ = try root.enumerateRotatedSegments()
        } catch {
            throw projectRotatedTopologyEnumerationFailure(error)
        }
    }

    /// Branches on the centralized
    /// ``SegmentEnumeration/isDuplicateRotatedSegmentSequenceError(_:)``
    /// classifier: a duplicate-sequence rejection becomes
    /// `.removalBoundaryStale`; every other enumeration
    /// failure becomes `.operationFailed(.validateBoundary, ...)`
    /// and preserves the underlying URL and context.
    private func projectRotatedTopologyEnumerationFailure(
        _ error: InternalReadError
    ) -> FileLogStoreRemoveError {
        let (url, context) = extractInternalReadFailureURLAndContext(
            error, defaultURL: configuration.directory
        )
        if SegmentEnumeration.isDuplicateRotatedSegmentSequenceError(error) {
            return .removalBoundaryStale(url: url, context: context)
        }
        return .operationFailed(
            operation: .validateBoundary, url: url, context: context
        )
    }

    private func extractInternalReadFailureURLAndContext(
        _ error: InternalReadError,
        defaultURL: URL
    ) -> (URL, FileSystemErrorContext) {
        switch error {
        case let .operationFailed(_, url, context):
            (url, context)
        case .interiorCorruption:
            (defaultURL, FileSystemErrorContext(
                domain: FileSystemErrorContext.packageDomain,
                code: nil,
                description: "rotated topology enumeration failed"
            ))
        }
    }

    private func revalidateEntry(
        _ entry: RemovalBoundaryEntry,
        rootFD: Int32
    ) throws(FileLogStoreRemoveError) {
        let leaf = entry.url.lastPathComponent
        let descriptor = try openBoundarySegmentForRevalidation(
            rootFD: rootFD, leaf: leaf, url: entry.url
        )
        defer {
            // Best-effort validation descriptor cleanup; close failure after
            // boundary revalidation does not change removal semantics.
            _ = Darwin.close(descriptor)
        }
        let statBuf = try fstatBoundarySegment(
            descriptor: descriptor, url: entry.url
        )
        try assertBoundaryIdentityAndSize(entry: entry, statBuf: statBuf)
    }

    private func openBoundarySegmentForRevalidation(
        rootFD: Int32, leaf: String, url: URL
    ) throws(FileLogStoreRemoveError) -> Int32 {
        let descriptor = leaf.withCString { cName in
            Darwin.openat(rootFD, cName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor >= 0 { return descriptor }
        let savedErrno = errno
        if savedErrno == ENOENT || savedErrno == ELOOP {
            throw .removalBoundaryStale(
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: savedErrno == ENOENT
                        ? "boundary segment missing"
                        : "boundary segment replaced by symlink"
                )
            )
        }
        throw .operationFailed(
            operation: .validateBoundary,
            url: url,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "boundary segment descriptor open failed"
            )
        )
    }

    private func fstatBoundarySegment(
        descriptor: Int32, url: URL
    ) throws(FileLogStoreRemoveError) -> stat {
        var statBuf = stat()
        guard Darwin.fstat(descriptor, &statBuf) == 0 else {
            let savedErrno = errno
            throw .operationFailed(
                operation: .validateBoundary,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "boundary segment metadata read failed"
                )
            )
        }
        return statBuf
    }

    private func assertBoundaryIdentityAndSize(
        entry: RemovalBoundaryEntry, statBuf: stat
    ) throws(FileLogStoreRemoveError) {
        let currentIdentity = FileIdentity(
            device: statBuf.st_dev,
            inode: statBuf.st_ino
        )
        if currentIdentity != entry.fileIdentity {
            throw .removalBoundaryStale(
                url: entry.url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "file identity mismatch"
                )
            )
        }
        if UInt64(statBuf.st_size) < entry.exportedPrefixEnd {
            throw .removalBoundaryStale(
                url: entry.url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "segment shorter than exported prefix end"
                )
            )
        }
    }
}

// MARK: - Compaction

extension FileLogStore {
    /// Preserves the post-boundary suffix from `entry.url` in a
    /// unique sibling temp file, then atomically replaces the
    /// boundary-covered segment with the compacted replacement
    /// segment.
    ///
    /// The boundary segment's identity and size are revalidated
    /// against the freshly opened compaction read descriptor —
    /// not against the per-entry-revalidation snapshot — so a
    /// swap or truncate landing between per-entry revalidation
    /// and compaction read fails closed with
    /// `.removalBoundaryStale` before any temp creation or
    /// atomic replacement runs.
    func compactSegment(
        rootFD: Int32,
        entry: RemovalBoundaryEntry,
        leaf: String
    ) throws(FileLogStoreRemoveError) {
        try fireBeforeOpenCompactionReadSeam(url: entry.url)

        let readFD = try openSegmentForCompactionRead(
            rootFD: rootFD, leaf: leaf, url: entry.url
        )
        defer {
            // Best-effort read descriptor cleanup; close failure after
            // compaction read does not change removal semantics.
            _ = Darwin.close(readFD)
        }

        let readState = try revalidatedCompactionReadState(
            readFD: readFD, entry: entry
        )
        let tempLeaf = ".swift-logger-compact-\(UUID().uuidString).tmp"
        let tempFD = try createCompactionTemporary(
            rootFD: rootFD,
            leaf: tempLeaf,
            url: entry.url,
            permissions: readState.replacementPermissions
        )
        var tempFDIsOpen = true
        var tempCommitted = false
        defer {
            if tempFDIsOpen { _ = Darwin.close(tempFD) }
            if !tempCommitted {
                _ = tempLeaf.withCString { Darwin.unlinkat(rootFD, $0, 0) }
            }
        }

        try copySuffixToTemporary(
            readFD: readFD,
            tempFD: tempFD,
            startOffset: entry.exportedPrefixEnd,
            length: readState.suffixLength,
            url: entry.url
        )
        try syncCompactionTemporary(tempFD: tempFD, url: entry.url)
        // Mark the compaction temporary's raw fd as consumed
        // before invoking close. The `pendingCloseHandles`
        // queue retains owning `FileHandle`s for deferred close;
        // the compaction temporary is a raw descriptor closed
        // explicitly here. After a failed `close(2)` the fd is
        // in an undefined state and must not be closed a second
        // time, so the deferred cleanup skips it. Temp unlink
        // cleanup still runs because `tempCommitted` stays
        // false until the atomic replacement succeeds.
        tempFDIsOpen = false
        try closeCompactionTemporary(tempFD: tempFD, url: entry.url)
        try replaceSegmentAtomic(
            rootFD: rootFD, tempLeaf: tempLeaf, finalLeaf: leaf, url: entry.url
        )
        tempCommitted = true
    }

    private func fireBeforeOpenCompactionReadSeam(
        url: URL
    ) throws(FileLogStoreRemoveError) {
        guard let testSeam = onBeforeOpenCompactionReadForTesting else { return }
        do {
            try testSeam(url)
        } catch {
            throw .operationFailed(
                operation: .openSegment,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// State derived from the compaction-time revalidation of
    /// the boundary segment. Captures the suffix length used to
    /// size the compaction temporary and the permission bits
    /// (`0o777`) the replacement segment must carry across the
    /// atomic rename. Special mode bits (SUID, SGID, sticky)
    /// are not part of the compaction permission-preservation
    /// contract.
    fileprivate struct CompactionReadState {
        let suffixLength: UInt64
        let replacementPermissions: mode_t
    }

    /// Re-derives the post-boundary suffix length and the
    /// boundary segment's permission bits (`0o777`) from
    /// `readFD`'s current `fstat(2)`. The compaction-time
    /// revalidation rejects a boundary segment whose identity
    /// no longer matches the captured boundary entry or whose
    /// size dropped below `entry.exportedPrefixEnd` after the
    /// per-entry revalidation step completed. Permission bits
    /// flow into the compaction temporary so the atomic
    /// replacement preserves the boundary segment's original
    /// `0o777` permission bits rather than picking up the
    /// active umask at compaction time.
    private func revalidatedCompactionReadState(
        readFD: Int32, entry: RemovalBoundaryEntry
    ) throws(FileLogStoreRemoveError) -> CompactionReadState {
        let statBuf = try fstatBoundarySegment(
            descriptor: readFD, url: entry.url
        )
        try assertBoundaryIdentityAndSize(entry: entry, statBuf: statBuf)
        let suffixLength = UInt64(statBuf.st_size) - entry.exportedPrefixEnd
        let replacementPermissions = mode_t(statBuf.st_mode & 0o777)
        return CompactionReadState(
            suffixLength: suffixLength,
            replacementPermissions: replacementPermissions
        )
    }

    /// Opens the boundary segment for compaction read,
    /// classifying `ENOENT` and `ELOOP` as `.removalBoundaryStale`
    /// so a vanish or symlink swap landing between per-entry
    /// revalidation and compaction-read open fails closed
    /// without entering temp creation or atomic replacement.
    private func openSegmentForCompactionRead(
        rootFD: Int32, leaf: String, url: URL
    ) throws(FileLogStoreRemoveError) -> Int32 {
        let descriptor = leaf.withCString { cName in
            Darwin.openat(rootFD, cName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor >= 0 { return descriptor }
        let savedErrno = errno
        if savedErrno == ENOENT || savedErrno == ELOOP {
            throw .removalBoundaryStale(
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: savedErrno == ENOENT
                        ? "boundary segment missing on compaction-read open"
                        : "boundary segment replaced by symlink on compaction-read open"
                )
            )
        }
        throw .operationFailed(
            operation: .openSegment,
            url: url,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "compaction read descriptor open failed"
            )
        )
    }

    /// Creates the compaction temporary at `leaf` carrying the
    /// boundary segment's permission bits (`0o777`). Active
    /// umask can drop bits the boundary segment held, so
    /// `fchmod` re-applies the explicit permissions. Failure
    /// between `openat` and `fchmod` runs the close + unlink
    /// discipline so no partially-permissioned temp survives.
    private func createCompactionTemporary(
        rootFD: Int32, leaf: String, url: URL, permissions: mode_t
    ) throws(FileLogStoreRemoveError) -> Int32 {
        let descriptor = leaf.withCString { cName in
            Darwin.openat(
                rootFD, cName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                permissions
            )
        }
        if descriptor < 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .createCompactionTemporary,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "compaction temporary create failed"
                )
            )
        }
        if Darwin.fchmod(descriptor, permissions) != 0 {
            let savedErrno = errno
            _ = Darwin.close(descriptor)
            _ = leaf.withCString { Darwin.unlinkat(rootFD, $0, 0) }
            throw .operationFailed(
                operation: .createCompactionTemporary,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "compaction temporary permission-bit preservation failed"
                )
            )
        }
        return descriptor
    }

    private func copySuffixToTemporary(
        readFD: Int32,
        tempFD: Int32,
        startOffset: UInt64,
        length: UInt64,
        url: URL
    ) throws(FileLogStoreRemoveError) {
        if Darwin.lseek(readFD, off_t(startOffset), SEEK_SET) < 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .readPreservedSuffix,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "post-boundary suffix seek failed"
                )
            )
        }
        var remaining = length
        let bufferSize = 65536
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: 1
        )
        defer { buffer.deallocate() }
        while remaining > 0 {
            let toRead = Int(min(UInt64(bufferSize), remaining))
            let bytesRead = Darwin.read(readFD, buffer, toRead)
            if bytesRead < 0 {
                let savedErrno = errno
                if savedErrno == EINTR { continue }
                throw .operationFailed(
                    operation: .readPreservedSuffix,
                    url: url,
                    context: FileSystemErrorContext(
                        domain: NSPOSIXErrorDomain,
                        code: Int(savedErrno),
                        description: "post-boundary suffix read failed"
                    )
                )
            }
            if bytesRead == 0 {
                throw .operationFailed(
                    operation: .readPreservedSuffix,
                    url: url,
                    context: FileSystemErrorContext(
                        domain: FileSystemErrorContext.packageDomain,
                        code: nil,
                        description: "post-boundary suffix ended unexpectedly"
                    )
                )
            }
            try writeAllToCompactionTemporary(
                tempFD: tempFD, buffer: buffer, count: bytesRead, url: url
            )
            remaining -= UInt64(bytesRead)
        }
    }

    private func writeAllToCompactionTemporary(
        tempFD: Int32,
        buffer: UnsafeRawPointer,
        count: Int,
        url: URL
    ) throws(FileLogStoreRemoveError) {
        var written = 0
        while written < count {
            let result = Darwin.write(
                tempFD, buffer.advanced(by: written), count - written
            )
            if result < 0 {
                let savedErrno = errno
                if savedErrno == EINTR { continue }
                throw .operationFailed(
                    operation: .writeCompactionTemporaryBytes,
                    url: url,
                    context: FileSystemErrorContext(
                        domain: NSPOSIXErrorDomain,
                        code: Int(savedErrno),
                        description: "write(compaction temp) failed"
                    )
                )
            }
            if result == 0 {
                throw .operationFailed(
                    operation: .writeCompactionTemporaryBytes,
                    url: url,
                    context: FileSystemErrorContext(
                        domain: FileSystemErrorContext.packageDomain,
                        code: nil,
                        description: "writeReturnedZero"
                    )
                )
            }
            written += result
        }
    }

    private func syncCompactionTemporary(
        tempFD: Int32, url: URL
    ) throws(FileLogStoreRemoveError) {
        if Darwin.fsync(tempFD) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .syncCompactionTemporary,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "fsync(compaction temp) failed"
                )
            )
        }
    }

    private func closeCompactionTemporary(
        tempFD: Int32, url: URL
    ) throws(FileLogStoreRemoveError) {
        if Darwin.close(tempFD) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .closeCompactionTemporary,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "close(compaction temp) failed"
                )
            )
        }
    }

    private func replaceSegmentAtomic(
        rootFD: Int32,
        tempLeaf: String,
        finalLeaf: String,
        url: URL
    ) throws(FileLogStoreRemoveError) {
        let result = tempLeaf.withCString { src in
            finalLeaf.withCString { dst in
                Darwin.renameat(rootFD, src, rootFD, dst)
            }
        }
        if result != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .replaceSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "renameat(compaction temp -> segment) failed"
                )
            )
        }
    }
}
