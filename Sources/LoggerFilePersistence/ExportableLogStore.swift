import Foundation

/// Opt-in export/remove protocol surface that pairs byte-stable
/// export with a destructive removal lifecycle.
///
/// Conformance is opt-in. Storage-only consumers, such as the
/// `swift-logger-remote` remote-delivery queue, depend on
/// `PersistentLogStore` and do not need to pull the export /
/// remove surface. This separation keeps `removeExportedLogs()`
/// behind an explicit conformance boundary.
///
/// `removeExportedLogs()` is permitted to delete only the
/// exported prefix observed by a prior successful
/// `exportLogs(to:)`; accepted bytes admitted after the
/// successful export destination commit are preserved
/// byte-for-byte. The full API-observable removal contract
/// is owned by `Docs/APIDesign.md`.
public protocol ExportableLogStore: Sendable {
    func exportLogs(to url: URL) async throws
    func removeExportedLogs() async throws
}
