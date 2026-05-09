import Foundation

// Internal test-seam helpers used by package tests through @testable import.
// Do not make these APIs public or SPI.

// MARK: - Export test seams

extension FileLogStore {
    /// Fires the post-write export test seam. A throwing test seam projects
    /// onto `.operationFailed(.writeTemporaryDestinationBytes)`.
    /// The hook is `async` so tests can rendezvous through
    /// continuation-based primitives without blocking the
    /// cooperative pool.
    func fireOnAfterWritingTemporaryBytesSeam(
        tempURL: URL
    ) async throws(FileLogStoreExportError) {
        guard let hook = onAfterWritingTemporaryBytesForTesting else { return }
        do {
            try await hook()
        } catch {
            throw .operationFailed(
                operation: .writeTemporaryDestinationBytes,
                url: tempURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }

    /// Fires the pre-commit export test seam. A throwing test seam projects
    /// onto `.operationFailed(.commitDestination)` against the
    /// final destination URL.
    func fireOnBeforeCommitSeam(
        finalURL: URL
    ) throws(FileLogStoreExportError) {
        guard let hook = onBeforeCommitForTesting else { return }
        do {
            try hook()
        } catch {
            throw .operationFailed(
                operation: .commitDestination,
                url: finalURL,
                context: FileSystemErrorContext(from: error)
            )
        }
    }
}
