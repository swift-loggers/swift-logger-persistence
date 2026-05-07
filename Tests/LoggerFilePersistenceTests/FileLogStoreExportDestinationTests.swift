import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Destination-topology rejection coverage for byte-stable export.
@Suite("FileLogStore byte-stable export — destination topology")
struct FileLogStoreExportDestinationTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func makeStoreWithOneAcceptedLine(
        directory: URL
    ) async throws -> FileLogStore {
        let store = FileLogStore(configuration: .init(directory: directory, rotation: .never))
        let envelope = try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        )
        try await store.append(envelope)
        return store
    }
}

extension FileLogStoreExportDestinationTests {
    @Test(
        "Existing regular file destination is rejected and not overwritten",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func existingRegularFileNotOverwritten() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let destination = directory.appendingPathComponent("export.ndjson")
        let preExisting = Data("PRE-EXISTING\n".utf8)
        try preExisting.write(to: destination)

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.alreadyExistsAsRegularFile)")
        } catch {
            switch error {
            case .invalidDestination(.alreadyExistsAsRegularFile):
                ()
            default:
                Issue.record("expected .alreadyExistsAsRegularFile, got \(error)")
            }
        }
        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == preExisting)
    }

    @Test(
        "Existing symlink at destination is rejected and target is unmodified",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func existingSymlinkRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let externalTargetParent = Self.uniqueDirectory()
        try Self.makeDirectory(externalTargetParent)
        defer { FileLogStoreTestSupport.remove(externalTargetParent) }
        let externalTarget = externalTargetParent.appendingPathComponent("target.bin")
        let externalBytes = Data("EXTERNAL\n".utf8)
        try externalBytes.write(to: externalTarget)

        let destination = directory.appendingPathComponent("export.ndjson")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: externalTarget
        )

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.alreadyExistsAsSymlink)")
        } catch {
            switch error {
            case .invalidDestination(.alreadyExistsAsSymlink):
                ()
            default:
                Issue.record("expected .alreadyExistsAsSymlink, got \(error)")
            }
        }
        let externalAfter = try Data(contentsOf: externalTarget)
        #expect(externalAfter == externalBytes)
    }

    @Test(
        "Existing directory at destination is rejected",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func existingDirectoryRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let destination = directory.appendingPathComponent("export.ndjson")
        try Self.makeDirectory(destination)

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.alreadyExistsAsDirectory)")
        } catch {
            switch error {
            case .invalidDestination(.alreadyExistsAsDirectory):
                ()
            default:
                Issue.record("expected .alreadyExistsAsDirectory, got \(error)")
            }
        }
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(
            atPath: destination.path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test(
        "Parent path that is a regular file is rejected as parentDirectoryInvalid",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func parentDirectoryInvalidRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let nonDirParentParent = Self.uniqueDirectory()
        try Self.makeDirectory(nonDirParentParent)
        defer { FileLogStoreTestSupport.remove(nonDirParentParent) }
        let nonDirParent = nonDirParentParent.appendingPathComponent("not-a-dir")
        try Data("regular\n".utf8).write(to: nonDirParent)
        let destination = nonDirParent.appendingPathComponent("export.ndjson")

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.parentDirectoryInvalid)")
        } catch {
            switch error {
            case .invalidDestination(.parentDirectoryInvalid):
                ()
            default:
                Issue.record("expected .parentDirectoryInvalid, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(
        "Existing FIFO at destination is rejected as alreadyExistsAsNonRegular",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func existingFIFORejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let destination = directory.appendingPathComponent("export.ndjson")
        let mkfifoResult = destination.path.withCString { cPath in
            Darwin.mkfifo(cPath, mode_t(0o600))
        }
        #expect(mkfifoResult == 0)

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.alreadyExistsAsNonRegular)")
        } catch {
            switch error {
            case .invalidDestination(.alreadyExistsAsNonRegular):
                ()
            default:
                Issue.record("expected .alreadyExistsAsNonRegular, got \(error)")
            }
        }
        var statBuf = stat()
        let lstatResult = destination.path.withCString { cPath in
            lstat(cPath, &statBuf)
        }
        #expect(lstatResult == 0)
        #expect((statBuf.st_mode & S_IFMT) == S_IFIFO)
    }

    @Test(
        "Absent parent directory is rejected as parentDirectoryAbsent",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func parentDirectoryAbsentRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        let missingParent = Self.uniqueDirectory()
            .appendingPathComponent("does-not-exist")
        let destination = missingParent.appendingPathComponent("export.ndjson")

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected invalidDestination(.parentDirectoryAbsent)")
        } catch {
            switch error {
            case .invalidDestination(.parentDirectoryAbsent):
                ()
            default:
                Issue.record("expected .parentDirectoryAbsent, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(
        "Non-file destination URL is rejected with .validateDestination",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func nonFileDestinationURLIsRejected() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }
        let store = try await Self.makeStoreWithOneAcceptedLine(directory: directory)

        guard let destination = URL(string: "https://example.com/export.ndjson") else {
            Issue.record("failed to construct https test URL")
            return
        }

        do {
            try await store.exportLogs(to: destination)
            Issue.record("expected .operationFailed(.validateDestination)")
        } catch {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .validateDestination)
                #expect(url == destination)
            default:
                Issue.record("expected .operationFailed(.validateDestination), got \(error)")
            }
        }
    }
}
