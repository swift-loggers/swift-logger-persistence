import Darwin
import Foundation

// MARK: - Per-segment write

extension FileLogStore {
    func writeSegmentsToTemp(
        root: SegmentRoot,
        segments: [URL],
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) -> [RemovalBoundaryEntry] {
        var entries: [RemovalBoundaryEntry] = []
        for segmentURL in segments {
            if let entry = try writeSegmentToTemp(
                root: root,
                segmentURL: segmentURL,
                tempFD: tempFD,
                tempURL: tempURL
            ) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func writeSegmentToTemp(
        root: SegmentRoot,
        segmentURL: URL,
        tempFD: Int32,
        tempURL: URL
    ) throws(FileLogStoreExportError) -> RemovalBoundaryEntry? {
        let handle: FileHandle
        do {
            handle = try root.openSegmentForReading(url: segmentURL)
        } catch {
            throw FileLogStoreExportError(
                projecting: error,
                onto: .openSegment
            )
        }
        defer { closeExportSegmentReadHandle(handle) }

        let boundary = try resolveExportBoundary(
            handle: handle, segmentURL: segmentURL
        )
        if boundary == 0 { return nil }
        let identity = try captureSegmentIdentity(
            handle: handle, segmentURL: segmentURL
        )
        try copySegmentBytesToTemp(
            handle: handle,
            boundary: boundary,
            segmentURL: segmentURL,
            tempFD: tempFD,
            tempURL: tempURL
        )
        return RemovalBoundaryEntry(
            url: segmentURL,
            numericSequence: SegmentEnumeration.parsedSequence(
                in: segmentURL.lastPathComponent
            ),
            fileIdentity: identity,
            exportedPrefixEnd: boundary
        )
    }

    /// Closes an export segment handle; failed closes are retried later.
    private func closeExportSegmentReadHandle(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            retainPendingCloseHandle(handle)
        }
    }

    /// Resolves the recoverable-prefix boundary for export.
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

    /// Streams the segment's recoverable prefix into `tempFD`.
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
            // Keep export writes bounded by the resolved recoverable prefix.
            let chunkCount = UInt64(chunk.count)
            guard chunkCount <= remaining else {
                throw .operationFailed(
                    operation: .readSegmentBytes,
                    url: segmentURL,
                    context: FileSystemErrorContext(
                        domain: FileSystemErrorContext.packageDomain,
                        code: nil,
                        description: "readPastBoundary"
                    )
                )
            }
            try writeAllToTemporary(chunk, tempFD: tempFD, tempURL: tempURL)
            remaining -= chunkCount
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
                if result == 0 {
                    failure = .operationFailed(
                        operation: .writeTemporaryDestinationBytes,
                        url: tempURL,
                        context: FileSystemErrorContext(
                            domain: FileSystemErrorContext.packageDomain,
                            code: nil,
                            description: "writeReturnedZero"
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
