import Foundation

// MARK: - Destination URL validation

extension FileLogStore {
    /// Rejects a non-file destination URL before any path-based
    /// derivation runs; Foundation's `URL` path accessors can
    /// produce surprising local paths for non-file schemes.
    func validateExportDestinationURL(
        _ url: URL
    ) throws(FileLogStoreExportError) {
        guard url.isFileURL else {
            throw .operationFailed(
                operation: .validateDestination,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "destination URL is not a file URL"
                )
            )
        }
    }

    /// Defensive check that the parent URL derived from the
    /// destination is itself a file URL.
    func validateExportParentURL(
        _ parentURL: URL,
        finalURL: URL
    ) throws(FileLogStoreExportError) {
        guard parentURL.isFileURL else {
            throw .operationFailed(
                operation: .validateDestination,
                url: finalURL,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "destination parent URL is not a file URL"
                )
            )
        }
    }
}
