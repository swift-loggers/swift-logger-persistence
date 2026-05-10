import Foundation
import Testing

/// Spawns `UmaskRegressionChild` under a controlled umask and
/// drains its stdio without deadlocking the parent. Encapsulates
/// binary-resolution, pipe-drain, and clean-exit assertion logic
/// shared across the umask-permission regression tests.
enum UmaskRegressionChildHarness {
    struct Result {
        let exitStatus: Int32
        let terminationReason: Process.TerminationReason
        let stdout: String
        let stderr: String
    }

    enum LocationError: Error {
        case binaryNotFound
        case binaryAmbiguous([String])
    }

    /// Runs the child with the requested umask + rotation, draining
    /// stdout/stderr concurrently with execution so a chatty child
    /// cannot deadlock the parent on a full pipe before exit.
    static func run(
        umaskOctal: String,
        directory: URL,
        rotation: String
    ) async throws -> Result {
        let binary = try resolveBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = [umaskOctal, directory.path, rotation]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Drain after `run()` so a `run()` failure does not leak GCD
        // readers blocked on a pipe with no writer. Process wait runs
        // on a dedicated `DispatchQueue` thread so the blocking
        // `waitUntilExit` never sits on the cooperative async executor.
        async let stdoutData: Data = drainPipeHandle(stdoutPipe.fileHandleForReading)
        async let stderrData: Data = drainPipeHandle(stderrPipe.fileHandleForReading)
        async let exitWait: Void = waitForProcessExit(process)

        let (stdout, stderr, _) = try await (stdoutData, stderrData, exitWait)

        return Result(
            exitStatus: process.terminationStatus,
            terminationReason: process.terminationReason,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    /// Records a child-failure diagnostic, then asserts termination
    /// reason before requiring exit status so a signal-kill failure
    /// is captured even when `#require` short-circuits the test path.
    static func expectChildExitedCleanly(_ result: Result) throws {
        if result.exitStatus != 0 || result.terminationReason != .exit {
            Issue.record(
                """
                UmaskRegressionChild exit \(result.exitStatus) \
                reason \(result.terminationReason.rawValue); \
                stdout: \(result.stdout); stderr: \(result.stderr)
                """
            )
        }
        #expect(result.terminationReason == .exit)
        try #require(result.exitStatus == 0)
    }

    /// Locates the `UmaskRegressionChild` executable target binary in
    /// the SwiftPM `.build/` directory. Tries the canonical
    /// `<packageRoot>/.build/debug/UmaskRegressionChild` first;
    /// falls back to enumerating `.build/` for a unique match.
    private static func resolveBinary(
        sourceFile: String = #filePath
    ) throws -> URL {
        // .../Tests/LoggerFilePersistenceTests/UmaskRegressionChildHarness.swift
        // → walk up to the package root.
        let testFileURL = URL(fileURLWithPath: sourceFile)
        let packageRoot = testFileURL
            .deletingLastPathComponent() // LoggerFilePersistenceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let buildRoot = packageRoot.appendingPathComponent(".build")

        // Canonical SwiftPM debug layout is the primary lookup so a
        // co-existing arch-specific build does not race the unique-match
        // ambiguity rule.
        let canonical = buildRoot
            .appendingPathComponent("debug")
            .appendingPathComponent("UmaskRegressionChild")
        if isRegularExecutableFile(at: canonical) {
            return canonical
        }

        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LocationError.binaryNotFound
        }
        var candidates: [URL] = []
        for case let url as URL in enumerator
            where url.lastPathComponent == "UmaskRegressionChild"
            && isRegularExecutableFile(at: url) {
            candidates.append(url)
        }
        candidates.sort { $0.path < $1.path }

        switch candidates.count {
        case 0:
            throw LocationError.binaryNotFound
        case 1:
            return candidates[0]
        default:
            throw LocationError.binaryAmbiguous(candidates.map(\.path))
        }
    }

    private static func isRegularExecutableFile(at url: URL) -> Bool {
        let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        return isRegular && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func drainPipeHandle(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? handle.close() }
                do {
                    let data = try handle.readToEnd() ?? Data()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func waitForProcessExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
