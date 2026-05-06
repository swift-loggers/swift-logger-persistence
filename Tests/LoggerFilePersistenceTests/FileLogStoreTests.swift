import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

@Suite("FileLogStore append/flush write path")
struct FileLogStoreTests {
    private static let baselineId = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )

    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerFilePersistenceTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func makeEnvelope(
        sequence: UInt64 = 1,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        contentType: String = "application/vnd.test.v1+json",
        hints: [String: String] = [:],
        payload: Data = Data([0x01, 0x02, 0x03])
    ) throws -> PersistentLogEnvelope {
        try PersistentLogEnvelope(
            id: baselineId,
            sequence: sequence,
            createdAt: timestamp,
            contentType: contentType,
            hints: hints,
            payload: payload
        )
    }

    private static func segmentURL(in directory: URL) -> URL {
        directory.appendingPathComponent("log.ndjson")
    }

    // MARK: Successful admission

    @Test(
        "First append creates the segment directory, file, and writes one canonical line",
        .tags(.lgp21, .lgp25, .lgp26)
    )
    func firstAppendCreatesSegmentAndWritesCanonicalLine() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        try await store.append(try Self.makeEnvelope())
        let segment = Self.segmentURL(in: directory)
        let bytes = try Data(contentsOf: segment)
        let text = try #require(String(data: bytes, encoding: .utf8))
        let expected = ##"{"contentType":"application\/vnd.test.v1+json","## +
            ##""createdAt":"2023-11-14T22:13:20.000Z","hints":{},"## +
            ##""id":"00000000-0000-0000-0000-000000000001","## +
            ##""payload":"AQID","sequence":1}"## + "\n"
        #expect(text == expected)
    }

    @Test(
        "Sequential appends produce one accepted line per call in caller order",
        .tags(.lgp1, .lgp11, .lgp25)
    )
    func sequentialAppendsProduceOneLinePerCall() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        for sequence in 1 ... 5 {
            try await store.append(try Self.makeEnvelope(sequence: UInt64(sequence)))
        }
        let bytes = try Data(contentsOf: Self.segmentURL(in: directory))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // `split` produces one trailing empty element after the final LF.
        #expect(lines.count == 6)
        #expect(lines.last == "")
        for sequence in 1 ... 5 {
            #expect(lines[sequence - 1].contains(##""sequence":\##(sequence)"##))
        }
    }

    // MARK: Flush

    @Test(
        "Flush before any append is a no-op",
        .tags(.lgp5, .lgp12)
    )
    func flushBeforeAppendIsNoOp() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        try await store.flush()
        #expect(!FileManager.default.fileExists(atPath: Self.segmentURL(in: directory).path))
    }

    @Test(
        "Flush after append synchronizes without changing accepted bytes",
        .tags(.lgp5, .lgp12, .lgp27)
    )
    func flushAfterAppendSynchronizes() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        try await store.append(try Self.makeEnvelope())
        let beforeFlush = try Data(contentsOf: Self.segmentURL(in: directory))
        try await store.flush()
        let afterFlush = try Data(contentsOf: Self.segmentURL(in: directory))
        #expect(beforeFlush == afterFlush)
    }

    // MARK: Pre-admission validation

    @Test(
        "Oversized encoded line is rejected with `.encodedEnvelopeLineTooLarge` before storage mutation",
        .tags(.lgp13, .lgp22, .lgp24, .lgp38)
    )
    func oversizedEncodedLineIsRejected() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        // 1 MiB of `0xFF` bytes encodes as ~1.4 MB of base64 `/`
        // characters; each `/` escapes as `\/` in canonical JSON,
        // pushing the encoded line past the spec's 2 MiB cap while
        // the raw payload remains within the envelope's 1 MiB limit.
        let payload = Data(repeating: 0xFF, count: 1_048_576)
        let envelope = try Self.makeEnvelope(payload: payload)
        await #expect(throws: FileLogStoreError.self) {
            try await store.append(envelope)
        }
        #expect(!FileManager.default.fileExists(atPath: Self.segmentURL(in: directory).path))
    }

    @Test(
        "Oversized encoded line surfaces the spec's typed validation error",
        .tags(.lgp2, .lgp22, .lgp38)
    )
    func oversizedEncodedLineSurfacesTypedValidationError() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        let payload = Data(repeating: 0xFF, count: 1_048_576)
        let envelope = try Self.makeEnvelope(payload: payload)
        do {
            try await store.append(envelope)
            Issue.record("expected oversized line to throw .invalidEnvelope")
        } catch {
            switch error {
            case let .invalidEnvelope(.encodedEnvelopeLineTooLarge(limit, actual)):
                #expect(limit == FileLogStore.maxEncodedLineBytes)
                #expect(actual > limit)
            default:
                Issue.record("expected .invalidEnvelope(.encodedEnvelopeLineTooLarge), got \(error)")
            }
        }
    }

    // MARK: Concurrency and serialization

    @Test(
        "Concurrent appends serialize through the actor and admit every envelope",
        .tags(.lgp1, .lgp11)
    )
    func concurrentAppendsSerializeThroughActor() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let store = FileLogStore(configuration: .init(directory: directory))
        let count = 32
        await withTaskGroup(of: Void.self) { group in
            for sequence in 1 ... count {
                let envelope = try? Self.makeEnvelope(sequence: UInt64(sequence))
                group.addTask {
                    if let envelope { try? await store.append(envelope) }
                }
            }
        }
        try await store.flush()
        let bytes = try Data(contentsOf: Self.segmentURL(in: directory))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == count)
        // Extract the sequence numerically from each line so
        // substring overlap (e.g. `:1` matching `:10`) cannot mask
        // a missed admission.
        var observed: Set<Int> = []
        for line in lines {
            let lineData = try #require(String(line).data(using: .utf8))
            let json = try #require(
                JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            )
            let nsNumber = try #require(json["sequence"] as? NSNumber)
            observed.insert(nsNumber.intValue)
        }
        #expect(observed == Set(1 ... count))
    }

    // MARK: Persistence across stores

    @Test(
        "Reopening a store appends to the existing segment file rather than truncating it",
        .tags(.lgp11, .lgp25, .lgp27)
    )
    func reopeningStoreAppendsToExistingSegment() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        do {
            let store = FileLogStore(configuration: .init(directory: directory))
            try await store.append(try Self.makeEnvelope(sequence: 1))
            try await store.flush()
        }
        do {
            let store = FileLogStore(configuration: .init(directory: directory))
            try await store.append(try Self.makeEnvelope(sequence: 2))
            try await store.flush()
        }
        let bytes = try Data(contentsOf: Self.segmentURL(in: directory))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains(##""sequence":1"##))
        #expect(lines[1].contains(##""sequence":2"##))
    }

    // MARK: Trailing-suffix trimming on reopen

    @Test(
        "Reopening a segment with a trailing partial suffix discards the suffix before append",
        .tags(.lgp14, .lgp15, .lgp16, .lgp24, .lgp25)
    )
    func reopenWithPartialSuffixDiscardsSuffix() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        let segmentURL = Self.segmentURL(in: directory)
        // Seed a real accepted canonical line via the store, then
        // append an undefined suffix to simulate a crash mid-write.
        do {
            let store = FileLogStore(configuration: .init(directory: directory))
            try await store.append(try Self.makeEnvelope(sequence: 1))
            try await store.flush()
        }
        let acceptedBytes = try Data(contentsOf: segmentURL)
        let partial = Data("partial-suffix-no-LF".utf8)
        try (acceptedBytes + partial).write(to: segmentURL)
        let reopened = FileLogStore(configuration: .init(directory: directory))
        try await reopened.append(try Self.makeEnvelope(sequence: 2))
        try await reopened.flush()
        let bytes = try Data(contentsOf: segmentURL)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("partial-suffix-no-LF"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains(##""sequence":1"##))
        #expect(lines[1].contains(##""sequence":2"##))
    }

    @Test(
        "Reopening a segment ending exactly at LF preserves every accepted line",
        .tags(.lgp11, .lgp14, .lgp25, .lgp27)
    )
    func reopenWithCleanTailPreservesAcceptedLines() async throws {
        let directory = Self.uniqueDirectory()
        defer { Self.remove(directory) }
        do {
            let store = FileLogStore(configuration: .init(directory: directory))
            try await store.append(try Self.makeEnvelope(sequence: 1))
            try await store.append(try Self.makeEnvelope(sequence: 2))
            try await store.flush()
        }
        let reopened = FileLogStore(configuration: .init(directory: directory))
        try await reopened.append(try Self.makeEnvelope(sequence: 3))
        try await reopened.flush()
        let bytes = try Data(contentsOf: Self.segmentURL(in: directory))
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines[0].contains(##""sequence":1"##))
        #expect(lines[1].contains(##""sequence":2"##))
        #expect(lines[2].contains(##""sequence":3"##))
    }

    // MARK: Encoded-line shape invariant (P2)

    @Test(
        "Missing trailing LF surfaces as `.encodedEnvelopeMissingTrailingLF`",
        .tags(.lgp21, .lgp25, .lgp26)
    )
    func missingTrailingLFSurfacesAsInvariantViolation() throws {
        let bytes = Data(##"{"id":"x"}"##.utf8) // no LF
        do {
            try FileLogStore.validateTrailingLF(bytes)
            Issue.record("expected .encodedEnvelopeMissingTrailingLF")
        } catch {
            #expect(error == .implementationInvariantViolation(
                violation: .encodedEnvelopeMissingTrailingLF
            ))
        }
    }

    @Test(
        "Interior LF surfaces as `.encodedEnvelopeContainsInteriorLF`",
        .tags(.lgp21, .lgp25, .lgp26)
    )
    func interiorLFSurfacesAsInvariantViolation() throws {
        // Two LF-terminated objects in one append unit.
        let bytes = Data("{\"id\":\"a\"}\n{\"id\":\"b\"}\n".utf8)
        do {
            try FileLogStore.validateNoInteriorLF(bytes)
            Issue.record("expected .encodedEnvelopeContainsInteriorLF")
        } catch {
            #expect(error == .implementationInvariantViolation(
                violation: .encodedEnvelopeContainsInteriorLF
            ))
        }
    }

    @Test(
        "Well-formed single-line bytes pass both shape invariants",
        .tags(.lgp21, .lgp25, .lgp26)
    )
    func wellFormedShapePassesInvariants() throws {
        let bytes = Data(##"{"id":"x"}"##.utf8) + Data([0x0A])
        try FileLogStore.validateTrailingLF(bytes)
        try FileLogStore.validateNoInteriorLF(bytes)
    }
}
