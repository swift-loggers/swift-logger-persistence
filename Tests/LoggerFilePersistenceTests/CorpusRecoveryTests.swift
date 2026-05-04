import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Conformance corpus for corruption classification and recovery outcomes.
@Suite("Corpus recovery fixtures")
struct CorpusRecoveryTests {
    private static func fixtureURL(_ name: String) throws -> URL {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "bin",
                subdirectory: "Fixtures/Corpus"
            ),
            "missing corpus fixture \(name).bin"
        )
        return url
    }

    private static func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtureURL(name))
    }

    private static func uniqueSegmentURL() throws -> URL {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("log.000001.ndjson")
    }

    /// Asserts terminal interior corruption for a corpus fixture.
    private static func expectInteriorCorruption(
        fixture: String,
        classification: InternalCorruptionClass,
        expectedByteOffset: UInt64 = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let bytes = try Self.loadFixture(fixture)
        let segmentURL = try Self.uniqueSegmentURL()
        defer {
            FileLogStoreTestSupport.remove(segmentURL.deletingLastPathComponent())
        }
        try bytes.write(to: segmentURL)
        let handle = try FileHandle(forReadingFrom: segmentURL)
        defer { try? handle.close() }
        let outcomes = try RecoverablePrefixScanner.collect(
            handle: handle, segmentURL: segmentURL
        )
        #expect(!outcomes.isEmpty, sourceLocation: sourceLocation)
        guard case let .corrupt(byteOffset, observed) = outcomes.last else {
            Issue.record(
                "expected terminal .corrupt(\(classification)) for \(fixture)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(
            byteOffset == expectedByteOffset,
            sourceLocation: sourceLocation
        )
        #expect(
            observed == classification,
            sourceLocation: sourceLocation
        )
        // Corruption is terminal; only accepted lines may precede it.
        #expect(
            outcomes.dropLast().allSatisfy {
                if case .accepted = $0 { return true }
                return false
            },
            sourceLocation: sourceLocation
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: malformed-utf8.bin classifies as .malformedUTF8",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusMalformedUTF8() throws {
        try Self.expectInteriorCorruption(
            fixture: "malformed-utf8",
            classification: .malformedUTF8
        )
    }

    @Test(
        "Corpus: malformed-json.bin classifies as .malformedJSON",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusMalformedJSON() throws {
        try Self.expectInteriorCorruption(
            fixture: "malformed-json",
            classification: .malformedJSON
        )
    }

    @Test(
        "Corpus: non-object-json.bin classifies as .nonObjectJSON",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusNonObjectJSON() throws {
        try Self.expectInteriorCorruption(
            fixture: "non-object-json",
            classification: .nonObjectJSON
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: duplicate-top-level.bin classifies as .duplicateJSONMember",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp34, .lgp35, .lgp37, .lgp38)
    )
    func corpusDuplicateTopLevel() throws {
        try Self.expectInteriorCorruption(
            fixture: "duplicate-top-level",
            classification: .duplicateJSONMember
        )
    }

    @Test(
        "Corpus: duplicate-in-hints.bin classifies as .duplicateJSONMember",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp34, .lgp35, .lgp37, .lgp38)
    )
    func corpusDuplicateInHints() throws {
        try Self.expectInteriorCorruption(
            fixture: "duplicate-in-hints",
            classification: .duplicateJSONMember
        )
    }

    @Test(
        "Corpus: duplicate-surrogate-pair-equivalence.bin classifies as .duplicateJSONMember",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp34, .lgp35, .lgp37, .lgp38)
    )
    func corpusDuplicateSurrogatePairEquivalence() throws {
        try Self.expectInteriorCorruption(
            fixture: "duplicate-surrogate-pair-equivalence",
            classification: .duplicateJSONMember
        )
    }

    @Test(
        "Corpus: duplicate-in-nested-object.bin classifies as .duplicateJSONMember",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp34, .lgp35, .lgp37, .lgp38)
    )
    func corpusDuplicateInNestedObject() throws {
        try Self.expectInteriorCorruption(
            fixture: "duplicate-in-nested-object",
            classification: .duplicateJSONMember
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: malformed-base64.bin classifies as .malformedBase64",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusMalformedBase64() throws {
        try Self.expectInteriorCorruption(
            fixture: "malformed-base64",
            classification: .malformedBase64
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: invalid-envelope-missing-id.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeMissingID() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-missing-id",
            classification: .invalidEnvelope
        )
    }

    @Test(
        "Corpus: invalid-envelope-sequence-zero.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeSequenceZero() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-sequence-zero",
            classification: .invalidEnvelope
        )
    }

    @Test(
        "Corpus: invalid-envelope-uppercase-uuid.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeUppercaseUUID() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-uppercase-uuid",
            classification: .invalidEnvelope
        )
    }

    @Test(
        "Corpus: invalid-envelope-non-canonical-timestamp.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeNonCanonicalTimestamp() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-non-canonical-timestamp",
            classification: .invalidEnvelope
        )
    }

    @Test(
        "Corpus: invalid-envelope-non-canonical-sequence-decimal.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeNonCanonicalSequenceDecimal() throws {
        // `"sequence":1.0` decodes as `UInt64(1)` via JSONDecoder
        // but is not the canonical sequence byte spelling.
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-non-canonical-sequence-decimal",
            classification: .invalidEnvelope
        )
    }

    @Test(
        "Corpus: invalid-envelope-non-canonical-sequence-exponent.bin classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp35, .lgp37, .lgp38)
    )
    func corpusInvalidEnvelopeNonCanonicalSequenceExponent() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-envelope-non-canonical-sequence-exponent",
            classification: .invalidEnvelope
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: invalid-delimiter-crlf.bin classifies as .invalidDelimiter",
        .tags(.lgp14, .lgp17, .lgp21, .lgp26, .lgp33, .lgp35, .lgp36, .lgp37, .lgp38)
    )
    func corpusInvalidDelimiterCRLF() throws {
        try Self.expectInteriorCorruption(
            fixture: "invalid-delimiter-crlf",
            classification: .invalidDelimiter
        )
    }

    @Test(
        "Corpus: invalid-delimiter-mixed.bin reports the CRLF line as the corruption boundary",
        .tags(.lgp14, .lgp17, .lgp21, .lgp26, .lgp33, .lgp35, .lgp36, .lgp37, .lgp38)
    )
    func corpusInvalidDelimiterMixed() throws {
        // The first canonical envelope is 172 bytes (LF-terminated)
        // and the second uses CRLF; the corruption boundary is at
        // the start of the CRLF-terminated line.
        try Self.expectInteriorCorruption(
            fixture: "invalid-delimiter-mixed",
            classification: .invalidDelimiter,
            expectedByteOffset: 172
        )
    }
}

extension CorpusRecoveryTests {
    @Test(
        "Corpus: mixed-recovery.bin yields one .accepted then one .trailingPartial",
        .tags(.lgp14, .lgp15, .lgp16, .lgp33, .lgp36, .lgp38)
    )
    func corpusMixedRecoveryAcceptedPlusTrailingPartial() throws {
        let bytes = try Self.loadFixture("mixed-recovery")
        let segmentURL = try Self.uniqueSegmentURL()
        defer {
            FileLogStoreTestSupport.remove(segmentURL.deletingLastPathComponent())
        }
        try bytes.write(to: segmentURL)
        let handle = try FileHandle(forReadingFrom: segmentURL)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(
            handle: handle, segmentURL: segmentURL
        )
        // Canonical envelope is 172 bytes; trailing partial follows.
        let acceptedBytes = bytes.prefix(172)
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: Data(acceptedBytes)),
            .trailingPartial(byteOffset: 172)
        ])
    }

    @Test(
        "Corpus: accepted-then-malformed-json.bin yields .accepted at 0 then terminal .corrupt(.malformedJSON) at 172",
        .tags(.lgp14, .lgp17, .lgp33, .lgp35, .lgp36, .lgp37, .lgp38)
    )
    func corpusAcceptedPrefixThenMalformedJSON() throws {
        try Self.expectInteriorCorruption(
            fixture: "accepted-then-malformed-json",
            classification: .malformedJSON,
            expectedByteOffset: 172
        )
    }

    @Test(
        "Corpus: accepted-then-duplicate-top-level.bin yields .accepted at 0 then .duplicateJSONMember at 172",
        .tags(.lgp14, .lgp17, .lgp21, .lgp33, .lgp34, .lgp35, .lgp36, .lgp37, .lgp38)
    )
    func corpusAcceptedPrefixThenDuplicateTopLevel() throws {
        try Self.expectInteriorCorruption(
            fixture: "accepted-then-duplicate-top-level",
            classification: .duplicateJSONMember,
            expectedByteOffset: 172
        )
    }
}
