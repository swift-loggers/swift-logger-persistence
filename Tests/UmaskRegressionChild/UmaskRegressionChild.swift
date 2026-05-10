// Subprocess regression child for the umask-independent segment
// permission contract. Spawned by `FileLogStorePermissionsTests`
// to set a restrictive process umask and exercise the production
// segment-creation path; the parent test then asserts the on-disk
// segment mode is `0o600` regardless of umask.
//
// Args: <umask-octal> <directory-path> <rotation-kind>
//   rotation-kind ∈ {"never", "bySize"}.

import Darwin
import Foundation
import LoggerFilePersistence
import LoggerPersistence

@main
struct UmaskRegressionChild {
    static func main() async {
        do {
            try await run()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("UmaskRegressionChild error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data(
                "usage: UmaskRegressionChild <umask-octal> <directory> <never|bySize>\n".utf8
            ))
            exit(2)
        }
        guard let umaskValue = mode_t(arguments[1], radix: 8) else {
            FileHandle.standardError.write(Data(
                "invalid umask octal value: \(arguments[1])\n".utf8
            ))
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[2])
        let rotation = arguments[3]

        _ = umask(umaskValue)

        switch rotation {
        case "never":
            try await runNever(directory: directory)
        case "bySize":
            try await runBySize(directory: directory)
        default:
            FileHandle.standardError.write(Data(
                "invalid rotation kind: \(rotation); expected 'never' or 'bySize'\n".utf8
            ))
            exit(2)
        }
    }

    static func runNever(directory: URL) async throws {
        let store = FileLogStore(configuration: .init(directory: directory, rotation: .never))
        let envelope = try PersistentLogEnvelope(
            id: UUID(),
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.test.v1+json",
            hints: [:],
            payload: Data([0x01])
        )
        try await store.append(envelope)
        try await store.flush()
    }

    static func runBySize(directory: URL) async throws {
        let policy = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let store = FileLogStore(configuration: .init(
            directory: directory, rotation: policy
        ))
        // Two rotation-sized appends → at least one rotated segment file
        // is created under the restrictive umask.
        let payload = Data(repeating: 0x41, count: 800_000)
        for sequence in UInt64(1) ... UInt64(2) {
            let envelope = try PersistentLogEnvelope(
                id: UUID(),
                sequence: sequence,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentType: "application/vnd.test.v1+json",
                hints: [:],
                payload: payload
            )
            try await store.append(envelope)
        }
        try await store.flush()
    }
}
