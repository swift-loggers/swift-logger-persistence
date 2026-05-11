import Darwin
import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Permission and parent-symlink regression coverage for file-store
/// creation and export. Newly-created segment files are `0o600`,
/// enforced descriptor-relative via an explicit `fchmod`
/// permission-preservation step after `O_CREAT | O_EXCL` `openat`,
/// so the on-disk mode is umask-independent.
@Suite("FileLogStore filesystem permissions and parent-symlink topology")
struct FileLogStorePermissionsTests {
    private static func uniqueDirectory() -> URL {
        FileLogStoreTestSupport.uniqueDirectory()
    }

    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func lstatMode(of url: URL) throws -> mode_t {
        var statBuf = stat()
        let result = url.path.withCString { cPath in
            Darwin.lstat(cPath, &statBuf)
        }
        try #require(result == 0)
        return mode_t(statBuf.st_mode & 0o777)
    }

    @Test(
        "Created log directory is owner-only",
        .tags(.lgp25, .lgp26)
    )
    func defaultCreatedLogDirectoryIsOwnerOnly() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }

        let store = FileLogStore(configuration: .init(directory: directory))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        ))
        try await store.flush()

        let mode = try Self.lstatMode(of: directory)
        #expect(mode & 0o077 == 0)
        #expect(mode & 0o700 == 0o700)
    }

    @Test(
        "`.never` segment file is owner-only",
        .tags(.lgp25, .lgp26)
    )
    func neverRotationSegmentFileIsOwnerOnly() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }

        let store = FileLogStore(configuration: .init(
            directory: directory, rotation: .never
        ))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        ))
        try await store.flush()

        let segment = directory.appendingPathComponent("log.ndjson")
        let mode = try Self.lstatMode(of: segment)
        #expect(mode == 0o600)
        #expect(mode & 0o077 == 0)
    }

    @Test(
        "`.bySize` rotated segment files are owner-only",
        .tags(.lgp6, .lgp25, .lgp26, .lgp39)
    )
    func bySizeRotationSegmentFilesAreOwnerOnly() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }

        let lineSize = try FileLogStoreTestSupport.encodedLineSize(
            for: FileLogStoreTestSupport.makeEnvelope(sequence: 1)
        )
        let policy = try RotationPolicy.bySize(maxSegmentBytes: lineSize * 2)
        let store = FileLogStore(configuration: .init(
            directory: directory, rotation: policy
        ))

        // Two-line cap: first two appends fit segment 1, third
        // rotates; both segments must be owner-only at create time.
        for sequence in UInt64(1) ... UInt64(3) {
            try await store.append(
                try FileLogStoreTestSupport.makeEnvelope(sequence: sequence)
            )
        }
        try await store.flush()

        for sequence in UInt64(1) ... UInt64(2) {
            let segment = FileLogStoreTestSupport.rotatedSegmentURL(
                in: directory, sequence: sequence
            )
            let mode = try Self.lstatMode(of: segment)
            #expect(mode == 0o600)
            #expect(mode & 0o077 == 0)
        }
    }

    @Test(
        "Export rejects symlink destination parent",
        .tags(.lgp2, .lgp8, .lgp32)
    )
    func exportParentDirectoryAsSymlinkFailsClosed() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let store = FileLogStore(configuration: .init(
            directory: directory, rotation: .never
        ))
        try await store.append(try FileLogStoreTestSupport.makeEnvelope(
            sequence: 1, payload: Data([0x01])
        ))
        try await store.flush()

        // Export must not follow the destination parent symlink.
        let symlinkTarget = Self.uniqueDirectory()
        try Self.makeDirectory(symlinkTarget)
        defer { FileLogStoreTestSupport.remove(symlinkTarget) }

        // Symlink sits at the destination's parent path.
        let symlinkParent = Self.uniqueDirectory()
        let symlinkParentParent = symlinkParent.deletingLastPathComponent()
        try Self.makeDirectory(symlinkParentParent)
        defer { FileLogStoreTestSupport.remove(symlinkParent) }
        try FileManager.default.createSymbolicLink(
            at: symlinkParent, withDestinationURL: symlinkTarget
        )

        let destination = symlinkParent.appendingPathComponent("export.ndjson")
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

        // Caller-visible destination path: export must not have created
        // the file (no follow through the parent symlink).
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        // The symlink target must remain empty.
        let targetContents = try FileManager.default.contentsOfDirectory(
            at: symlinkTarget, includingPropertiesForKeys: nil
        )
        #expect(targetContents.isEmpty)
    }

    @Test(
        "Subprocess umask regression: `.never` segment file is exactly 0o600 under restrictive umask",
        .tags(.lgp25, .lgp26)
    )
    func subprocessUmaskRegressionNeverSegmentIs0o600() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        // `0o277` masks owner write + all group/world bits, so an
        // `openat` mode of `0o600` filtered through this umask would
        // create a `0o400` file. Production must `fchmod` back to
        // `0o600`.
        let result = try await UmaskRegressionChildHarness.run(
            umaskOctal: "0277",
            directory: directory,
            rotation: "never"
        )
        try UmaskRegressionChildHarness.expectChildExitedCleanly(result)

        let segment = directory.appendingPathComponent("log.ndjson")
        let mode = try Self.lstatMode(of: segment)
        #expect(mode == 0o600)
    }

    @Test(
        "Subprocess umask regression: `.bySize` rotated segment file is exactly 0o600 under restrictive umask",
        .tags(.lgp6, .lgp25, .lgp26, .lgp39)
    )
    func subprocessUmaskRegressionBySizeRotatedSegmentIs0o600() async throws {
        let directory = Self.uniqueDirectory()
        try Self.makeDirectory(directory)
        defer { FileLogStoreTestSupport.remove(directory) }

        let result = try await UmaskRegressionChildHarness.run(
            umaskOctal: "0277",
            directory: directory,
            rotation: "bySize"
        )
        try UmaskRegressionChildHarness.expectChildExitedCleanly(result)

        let segment = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        let mode = try Self.lstatMode(of: segment)
        #expect(mode == 0o600)
    }

    @Test(
        "Subprocess umask regression: created log directory is exactly 0o700 under restrictive umask",
        .tags(.lgp25, .lgp26)
    )
    func subprocessUmaskRegressionCreatedDirectoryIs0o700() async throws {
        // Parent does not pre-create the leaf so the child's
        // `FileLogStore` open path creates the directory under the
        // restrictive umask. `0o277` would filter `mkdir(0o700)`
        // down to `0o500`; production must re-apply `0o700`.
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }

        let result = try await UmaskRegressionChildHarness.run(
            umaskOctal: "0277",
            directory: directory,
            rotation: "never"
        )
        try UmaskRegressionChildHarness.expectChildExitedCleanly(result)

        let mode = try Self.lstatMode(of: directory)
        #expect(mode == 0o700)
    }

    @Test(
        "Directory permission-preservation failure admits no log bytes",
        .tags(.lgp25, .lgp26)
    )
    func directoryPermissionPreservationFailureAdmitsNoLogBytes() async throws {
        let directory = Self.uniqueDirectory()
        defer { FileLogStoreTestSupport.remove(directory) }

        let store = FileLogStore(configuration: .init(directory: directory))
        await store._setOnBeforeDirectoryChmodForTesting { _ in
            throw DirectoryChmodSentinelError()
        }
        defer { Task { await store._setOnBeforeDirectoryChmodForTesting(nil) } }

        do {
            try await store.append(try FileLogStoreTestSupport.makeEnvelope(
                sequence: 1, payload: Data([0x01])
            ))
            Issue.record("expected createDirectory failure to throw")
        } catch let error as FileLogStoreError {
            switch error {
            case let .operationFailed(operation, url, _):
                #expect(operation == .createDirectory)
                #expect(url == directory)
            default:
                Issue.record("expected .operationFailed(.createDirectory), got \(error)")
            }
        }

        // The seam fires after a successful `mkdir`, so the leaf
        // must exist as a directory. No admitted log bytes are
        // reachable: neither the `.never` segment nor any rotated
        // segment is present.
        var leafIsDirectory: ObjCBool = false
        let leafExists = FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &leafIsDirectory
        )
        #expect(leafExists)
        #expect(leafIsDirectory.boolValue)
        let neverSegment = directory.appendingPathComponent("log.ndjson")
        #expect(!FileManager.default.fileExists(atPath: neverSegment.path))
        let rotatedSegment = FileLogStoreTestSupport.rotatedSegmentURL(
            in: directory, sequence: 1
        )
        #expect(!FileManager.default.fileExists(atPath: rotatedSegment.path))
    }

    @Test(
        "Parent directory create failure admits no log bytes",
        .tags(.lgp25, .lgp26)
    )
    func parentDirectoryCreateFailureAdmitsNoLogBytes() async throws {
        // Pre-create the would-be intermediate parent as a regular
        // file so `createDirectoryParentsIfNeeded` cannot resolve
        // it as a directory; the failure must surface before any
        // writer-root open is attempted.
        let parent = Self.uniqueDirectory()
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }

        let directory = parent.appendingPathComponent("leaf")
        let store = FileLogStore(configuration: .init(directory: directory))
        await store._setOnBeforeWriterRootOpenForTesting { throw WriterRootSentinelError() }
        defer { Task { await store._setOnBeforeWriterRootOpenForTesting(nil) } }

        do {
            try await store.append(try FileLogStoreTestSupport.makeEnvelope(
                sequence: 1, payload: Data([0x01])
            ))
            Issue.record("expected createDirectory failure to throw")
        } catch let error as FileLogStoreError {
            switch error {
            case let .operationFailed(operation, url, _):
                // `.createDirectory` proves the failure surfaced
                // before writer-root open; a writer-root seam
                // firing would project to `.openWritableSegment`.
                #expect(operation == .createDirectory)
                #expect(url == directory)
            default:
                Issue.record("expected .operationFailed(.createDirectory), got \(error)")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let neverSegment = directory.appendingPathComponent("log.ndjson")
        #expect(!FileManager.default.fileExists(atPath: neverSegment.path))
    }
}

private struct DirectoryChmodSentinelError: Error {}
private struct WriterRootSentinelError: Error {}
