import Foundation

@testable import LoggerFilePersistence

/// Test-only convenience: drains the production iterator into an
/// `[LineOutcome]` array. Production code never collects per-line
/// outcomes; tests use this only to assert against expected lists.
extension RecoverablePrefixScanner {
    static func collect(
        handle: FileHandle,
        segmentURL: URL
    ) throws(InternalReadError) -> [LineOutcome] {
        var iterator = try Self.iterator(handle: handle, segmentURL: segmentURL)
        var outcomes: [LineOutcome] = []
        while let outcome = try iterator.next() {
            outcomes.append(outcome)
        }
        return outcomes
    }
}
