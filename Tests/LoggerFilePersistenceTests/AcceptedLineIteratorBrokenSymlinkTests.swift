import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for broken `log.ndjson` symlink handling under `.never`.
@Suite("AcceptedLineIterator broken symlink at log.ndjson")
struct AcceptedLineIteratorBrokenSymlinkTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
}

extension AcceptedLineIteratorBrokenSymlinkTests {
    @Test(
        "Under .never, a broken symlink at log.ndjson surfaces .operationFailed(.enumerateSegments)",
        .tags(.lgp2)
    )
    func neverPolicyBrokenSymlinkAtSegmentPathSurfacesError() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // Create a broken symlink at the unrotated segment path.
        let missingTarget = directory.appendingPathComponent("missing-target.bin")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("log.ndjson"),
            withDestinationURL: missingTarget
        )

        let configuration = FileLogStore.Configuration(
            directory: directory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        var collected: [Data] = []
        do {
            for try await bytes in stream {
                collected.append(bytes)
            }
            Issue.record("expected operationFailed(.enumerateSegments) for broken symlink")
        } catch let error as InternalReadError {
            #expect(collected.isEmpty)
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url.lastPathComponent == "log.ndjson")
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }
}
