import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Coverage for non-ENOENT failure projection at the configured root.
@Suite("SegmentEnumeration root-failure projection")
struct SegmentEnumerationLstatFailureTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
}

extension SegmentEnumerationLstatFailureTests {
    @Test(
        "Configured directory that is a regular file fails closed",
        .tags(.lgp2)
    )
    func unrotatedURLIfRegularThrowsWhenParentIsRegularFile() throws {
        let parentDir = Self.uniqueDirectory()
        try Self.makeDirectory(parentDir)
        defer { FileLogStoreTestSupport.remove(parentDir) }
        let regularFileAsDirectory = parentDir.appendingPathComponent("notADir")
        try Data().write(to: regularFileAsDirectory)

        do {
            _ = try SegmentEnumeration.unrotatedSegmentURLIfRegular(
                in: regularFileAsDirectory, fileManager: FileManager.default
            )
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url == regularFileAsDirectory)
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }

    @Test(
        "Iterator under .never with regular-file root fails closed",
        .tags(.lgp2)
    )
    func iteratorOverRegularFileDirectorySurfacesEnumerateError() async throws {
        let parentDir = Self.uniqueDirectory()
        try Self.makeDirectory(parentDir)
        defer { FileLogStoreTestSupport.remove(parentDir) }
        let regularFileAsDirectory = parentDir.appendingPathComponent("notADir")
        try Data().write(to: regularFileAsDirectory)

        let configuration = FileLogStore.Configuration(
            directory: regularFileAsDirectory, rotation: .never
        )
        let stream = AcceptedLineIterator.acceptedLines(
            configuration: configuration
        )
        var collected: [Data] = []
        do {
            for try await bytes in stream {
                collected.append(bytes)
            }
            Issue.record("expected operationFailed(.enumerateSegments)")
        } catch let error as InternalReadError {
            #expect(collected.isEmpty)
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .enumerateSegments)
                #expect(url == regularFileAsDirectory)
            case .interiorCorruption:
                Issue.record("expected operationFailed, got interiorCorruption")
            }
        }
    }
}
