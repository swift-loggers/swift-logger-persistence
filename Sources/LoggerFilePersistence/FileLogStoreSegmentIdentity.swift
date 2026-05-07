import Darwin
import Foundation

extension FileLogStore {
    /// Captures stable segment file identity from an open
    /// descriptor. Export records it on each removal-boundary
    /// entry; remove revalidates it to fail closed when an
    /// out-of-band mutation replaced the segment between export
    /// destination commit and removal.
    func captureSegmentIdentity(
        handle: FileHandle,
        segmentURL: URL
    ) throws(FileLogStoreExportError) -> FileIdentity {
        var statBuf = stat()
        let result = fstat(handle.fileDescriptor, &statBuf)
        guard result == 0 else {
            let savedErrno = errno
            throw .operationFailed(
                operation: .openSegment,
                url: segmentURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "segment identity read failed"
                )
            )
        }
        return FileIdentity(
            device: statBuf.st_dev,
            inode: statBuf.st_ino
        )
    }
}
