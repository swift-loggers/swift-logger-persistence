// swiftlint:disable file_length - Boundary revalidation, compaction temp create with permission preservation, post-boundary suffix range guard and streaming, and atomic replace are kept in one file so the compaction contract stays auditable in one place.
import Darwin
import Foundation

// MARK: - Boundary re-validation

extension FileLogStore {
    /// Revalidates removal boundary entries before mutation.
    ///
    /// Duplicate rotated topology and per-entry identity/size mismatches
    /// surface as `.removalBoundaryStale`; no disk mutation occurs.
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

    /// Projects duplicate rotated topology to `.removalBoundaryStale`.
    /// Other enumeration failures remain `.operationFailed(.validateBoundary)`.
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
    /// The boundary segment's identity and size are revalidated at
    /// compaction-read open AND immediately before the atomic
    /// replacement; a swap or truncate landing in either window
    /// fails closed with `.removalBoundaryStale` before the
    /// replacement runs.
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
        // Raw descriptor close consumes `tempFD`; failed close leaves it
        // undefined, so deferred cleanup must not close it again.
        tempFDIsOpen = false
        try closeCompactionTemporary(tempFD: tempFD, url: entry.url)
        try fireBeforeReplaceSegmentRevalidationSeam(url: entry.url)
        try revalidateEntry(entry, rootFD: rootFD)
        try replaceSegmentAtomic(
            rootFD: rootFD, tempLeaf: tempLeaf, finalLeaf: leaf, url: entry.url
        )
        tempCommitted = true
    }

    private func fireBeforeReplaceSegmentRevalidationSeam(
        url: URL
    ) throws(FileLogStoreRemoveError) {
        guard let testSeam = onBeforePreReplaceRevalidateForTesting else { return }
        do {
            try testSeam(url)
        } catch {
            throw .operationFailed(
                operation: .validateBoundary,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
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

    /// Compaction-time boundary state derived from the current segment
    /// descriptor.
    fileprivate struct CompactionReadState {
        let suffixLength: UInt64
        let replacementPermissions: mode_t
    }

    /// Revalidates the compaction read descriptor and derives suffix
    /// length plus owner-class replacement permissions.
    private func revalidatedCompactionReadState(
        readFD: Int32, entry: RemovalBoundaryEntry
    ) throws(FileLogStoreRemoveError) -> CompactionReadState {
        let statBuf = try fstatBoundarySegment(
            descriptor: readFD, url: entry.url
        )
        try assertBoundaryIdentityAndSize(entry: entry, statBuf: statBuf)
        let suffixLength = UInt64(statBuf.st_size) - entry.exportedPrefixEnd
        // Preserve owner-class bits only; compaction must not widen
        // segment permissions.
        let replacementPermissions = mode_t(statBuf.st_mode & 0o700)
        return CompactionReadState(
            suffixLength: suffixLength,
            replacementPermissions: replacementPermissions
        )
    }

    /// Opens the boundary segment for compaction read.
    ///
    /// Vanish or symlink replacement surfaces as `.removalBoundaryStale`.
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

    /// Creates the compaction temporary with owner-class permissions only.
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
            // Unlink before close: while the descriptor is still open
            // the path resolves to the temp object we just created, so
            // the unlink targets exactly that object.
            let unlinkResult = leaf.withCString { cName in
                Darwin.unlinkat(rootFD, cName, 0)
            }
            let unlinkErrno = unlinkResult != 0 ? errno : 0
            let closeResult = Darwin.close(descriptor)
            let closeErrno = closeResult != 0 ? errno : 0
            var description = "compaction temporary permission-bit preservation failed"
            if unlinkResult != 0 {
                description += "; cleanup unlink failed errno \(unlinkErrno)"
            }
            if closeResult != 0 {
                description += "; cleanup close failed errno \(closeErrno)"
            }
            throw .operationFailed(
                operation: .createCompactionTemporary,
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

    /// Guards the `off_t` cast and end-offset arithmetic so an
    /// out-of-range boundary fails closed as `.readPreservedSuffix`
    /// instead of trapping in `off_t(startOffset)`.
    private func validateSuffixRange(
        startOffset: UInt64,
        length: UInt64,
        url: URL
    ) throws(FileLogStoreRemoveError) {
        let offTMax = UInt64(off_t.max)
        let (endOffset, overflow) = startOffset.addingReportingOverflow(length)
        guard startOffset <= offTMax, !overflow, endOffset <= offTMax else {
            throw .operationFailed(
                operation: .readPreservedSuffix,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "post-boundary suffix range exceeds off_t"
                )
            )
        }
    }

    private func copySuffixToTemporary(
        readFD: Int32,
        tempFD: Int32,
        startOffset: UInt64,
        length: UInt64,
        url: URL
    ) throws(FileLogStoreRemoveError) {
        try validateSuffixRange(
            startOffset: startOffset, length: length, url: url
        )
        try seekToSuffixStart(readFD: readFD, startOffset: startOffset, url: url)
        try streamSuffixBytes(
            readFD: readFD, tempFD: tempFD, length: length, url: url
        )
    }

    private func seekToSuffixStart(
        readFD: Int32, startOffset: UInt64, url: URL
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
    }

    private func streamSuffixBytes(
        readFD: Int32, tempFD: Int32, length: UInt64, url: URL
    ) throws(FileLogStoreRemoveError) {
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
                        description: "compaction temporary write failed"
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
                        description: "compaction temporary write returned zero"
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
                    description: "compaction temporary sync failed"
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
                    description: "compaction temporary close failed"
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
                    description: "compaction replacement failed"
                )
            )
        }
    }
}
