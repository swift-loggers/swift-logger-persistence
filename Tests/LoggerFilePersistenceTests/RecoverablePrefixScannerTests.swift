import Foundation
import LoggerPersistence
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Recoverable-prefix scanner conformance tests.
@Suite("RecoverablePrefixScanner recoverable-prefix discovery")
struct RecoverablePrefixScannerTests {
    static func uniqueSegmentURL() throws -> URL {
        let directory = FileLogStoreTestSupport.uniqueDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("log.000001.ndjson")
    }

    static func writeSegment(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
    }

    static func openHandle(_ url: URL) throws -> FileHandle {
        try FileHandle(forReadingFrom: url)
    }

    static func canonicalLine(
        sequence: UInt64 = 1,
        contentType: String = "application/vnd.test.v1+json",
        hints: [String: String] = [:],
        payload: Data = Data([0x01, 0x02, 0x03])
    ) throws -> Data {
        let envelope = try PersistentLogEnvelope(
            id: FileLogStoreTestSupport.baselineId,
            sequence: sequence,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: contentType,
            hints: hints,
            payload: payload
        )
        return try CanonicalEnvelopeLineEncoder().encode(envelope)
    }
}

extension RecoverablePrefixScannerTests {
    @Test(
        "Scanning an empty segment yields no outcomes",
        .tags(.lgp14)
    )
    func emptySegmentYieldsNoOutcomes() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        try Self.writeSegment(Data(), to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes.isEmpty)
    }

    @Test(
        "A single accepted line yields one .accepted outcome at byte 0",
        .tags(.lgp14, .lgp18)
    )
    func singleAcceptedLineStartsAtByteZero() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let line = try Self.canonicalLine()
        try Self.writeSegment(line, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [.accepted(byteOffset: 0, bytes: line)])
    }

    @Test(
        "Multiple accepted lines are reported in file byte order with cumulative offsets",
        .tags(.lgp14, .lgp18)
    )
    func multipleAcceptedLinesReportedInByteOrder() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let line1 = try Self.canonicalLine(sequence: 1)
        let line2 = try Self.canonicalLine(sequence: 2)
        let line3 = try Self.canonicalLine(sequence: 3)
        try Self.writeSegment(line1 + line2 + line3, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: line1),
            .accepted(byteOffset: UInt64(line1.count), bytes: line2),
            .accepted(
                byteOffset: UInt64(line1.count + line2.count),
                bytes: line3
            )
        ])
    }

    @Test(
        "A trailing non-LF tail yields .trailingPartial",
        .tags(.lgp14, .lgp15, .lgp16, .lgp36)
    )
    func trailingPartialAtEndOfSegment() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let line = try Self.canonicalLine()
        let partial = Data([0x7B, 0x22]) // `{"`
        try Self.writeSegment(line + partial, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: line),
            .trailingPartial(byteOffset: UInt64(line.count))
        ])
        // Confirm read path is non-destructive: the segment bytes
        // on disk include the partial bytes verbatim.
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == line + partial)
    }

    @Test(
        "A segment containing only a non-LF-terminated tail yields .trailingPartial(byteOffset: 0)",
        .tags(.lgp14, .lgp15, .lgp16, .lgp18)
    )
    func partialOnlySegmentStartsAtByteZero() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        try Self.writeSegment(Data([0x7B, 0x22]), to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(handle: handle, segmentURL: url)
        #expect(outcomes == [.trailingPartial(byteOffset: 0)])
    }
}

extension RecoverablePrefixScannerTests {
    static func expectInteriorCorruption(
        _ bytes: Data,
        classification: InternalCorruptionClass,
        expectedByteOffset: UInt64 = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        try Self.writeSegment(bytes, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(
            handle: handle, segmentURL: url
        )
        #expect(!outcomes.isEmpty, sourceLocation: sourceLocation)
        guard case let .corrupt(byteOffset, observed) = outcomes.last else {
            Issue.record(
                "expected terminal .corrupt(\(classification))",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(byteOffset == expectedByteOffset, sourceLocation: sourceLocation)
        #expect(observed == classification, sourceLocation: sourceLocation)
        // Corruption is terminal; only accepted lines may precede it.
        #expect(
            outcomes.dropLast().allSatisfy {
                if case .accepted = $0 { return true }
                return false
            },
            sourceLocation: sourceLocation
        )
    }

    @Test(
        "malformed UTF-8 inside an LF-terminated line classifies as .malformedUTF8",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func interiorMalformedUTF8() throws {
        // `0xC3 0x28` is an invalid UTF-8 sequence (a leading byte
        // for a 2-byte sequence followed by a non-continuation byte).
        try Self.expectInteriorCorruption(
            Data([0xC3, 0x28, 0x0A]),
            classification: .malformedUTF8
        )
    }

    @Test(
        "an LF-terminated line that is not parseable JSON classifies as .malformedJSON",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func interiorMalformedJSON() throws {
        // Unterminated JSON string.
        let bytes = Data(##"{"a":"b"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .malformedJSON)
    }

    @Test(
        "an LF-terminated JSON value that is not an object classifies as .nonObjectJSON",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func interiorNonObjectJSON() throws {
        let bytes = Data("[1,2,3]".utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .nonObjectJSON)
    }

    @Test(
        "duplicate top-level member name classifies as .duplicateJSONMember despite Foundation parser silence",
        .tags(.lgp14, .lgp17, .lgp21, .lgp34, .lgp35, .lgp36, .lgp37)
    )
    func interiorDuplicateTopLevelMember() throws {
        let bytes = Data(##"{"sequence":1,"sequence":2}"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .duplicateJSONMember)
    }

    @Test(
        "duplicate hint key inside the hints object classifies as .duplicateJSONMember",
        .tags(.lgp14, .lgp17, .lgp21, .lgp34, .lgp35, .lgp36, .lgp37)
    )
    func interiorDuplicateInHintsObject() throws {
        let bytes = Data(##"{"hints":{"a":"x","a":"y"}}"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .duplicateJSONMember)
    }

    @Test(
        "a JSON object missing a required envelope key classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func interiorInvalidEnvelopeMissingField() throws {
        // A valid JSON object that does not satisfy the envelope shape.
        let bytes = Data(##"{"unrelated":1}"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "a payload field that is not standard base64 classifies as .malformedBase64",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func interiorMalformedBase64Payload() throws {
        // Construct a shape-valid envelope but with a non-base64
        // payload value.
        let body = ##"{"contentType":"application\/x","## +
            ##""createdAt":"2023-11-14T22:13:20.000Z","## +
            ##""hints":{},"## +
            ##""id":"00000000-0000-0000-0000-000000000001","## +
            ##""payload":"@@@@","sequence":1}"##
        let bytes = Data(body.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .malformedBase64)
    }

    @Test(
        "a CRLF-terminated line classifies as .invalidDelimiter, not .malformedJSON",
        .tags(.lgp14, .lgp17, .lgp26, .lgp35, .lgp36, .lgp37)
    )
    func interiorInvalidDelimiterCRLF() throws {
        // Use a canonical envelope line and replace its trailing
        // LF with CRLF so the body remains parseable JSON; only the
        // delimiter is wrong.
        let canonical = try Self.canonicalLine()
        let bodyWithoutLF = canonical.dropLast()
        let crlfTerminated = bodyWithoutLF + Data([0x0D, 0x0A])
        try Self.expectInteriorCorruption(
            crlfTerminated,
            classification: .invalidDelimiter
        )
    }

    @Test(
        "mixed CRLF/LF content reports the CRLF line as the corruption boundary at its starting byte offset",
        .tags(.lgp14, .lgp17, .lgp26, .lgp35, .lgp36, .lgp37)
    )
    func mixedDelimitersHardStopAtCRLFLine() throws {
        let line1 = try Self.canonicalLine(sequence: 1)
        let line2Body = try Self.canonicalLine(sequence: 2).dropLast()
        let line2CRLF = line2Body + Data([0x0D, 0x0A])
        let bytes = Data(line1) + Data(line2CRLF)
        try Self.expectInteriorCorruption(
            bytes,
            classification: .invalidDelimiter,
            expectedByteOffset: UInt64(line1.count)
        )
    }
}

extension RecoverablePrefixScannerTests {
    /// Replaces one canonical envelope member value verbatim.
    private static func envelopeLine(
        replacing key: String,
        with replacement: String
    ) throws -> Data {
        let canonical = try Self.canonicalLine()
        var line = try #require(String(data: canonical, encoding: .utf8))
        let pattern = "\"\(key)\":"
        guard let keyRange = line.range(of: pattern) else {
            Issue.record("canonical line missing key \(key)")
            return canonical
        }
        let valueStart = keyRange.upperBound
        // Locate the JSON value's end: scan to next `,` or `}` at
        // top-level depth (envelope keys' values are non-nested
        // primitives or the `hints` object).
        let valueEnd = Self.endOfJSONValue(in: line, from: valueStart)
        line.replaceSubrange(valueStart ..< valueEnd, with: replacement)
        return Data(line.utf8)
    }

    /// Returns the end index of one JSON value.
    private static func endOfJSONValue(in line: String, from: String.Index) -> String.Index {
        var state = JSONValueWalkerState()
        var index = from
        while index < line.endIndex {
            if state.consume(line[index]) == .stopBefore {
                return index
            }
            index = line.index(after: index)
        }
        return index
    }

    private struct JSONValueWalkerState {
        enum Step { case advance, stopBefore }
        var depth = 0
        var inString = false
        var escape = false

        mutating func consume(_ char: Character) -> Step {
            if inString {
                consumeInString(char)
                return .advance
            }
            return consumeOutsideString(char)
        }

        private mutating func consumeInString(_ char: Character) {
            if escape {
                escape = false
            } else if char == "\\" {
                escape = true
            } else if char == "\"" {
                inString = false
            }
        }

        private mutating func consumeOutsideString(_ char: Character) -> Step {
            switch char {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
            case "}", "]":
                if depth == 0 { return .stopBefore }
                depth -= 1
            case ",":
                if depth == 0 { return .stopBefore }
            default:
                break
            }
            return .advance
        }
    }

    @Test(
        "envelope with sequence:0 (reserved) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeReservedSequenceZero() throws {
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "0")
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with fractional sequence (1.5) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeFractionalSequence() throws {
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "1.5")
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with negative sequence (-1) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeNegativeSequence() throws {
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "-1")
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with non-canonical decimal sequence (1.0) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeNonCanonicalDecimalSequence() throws {
        // `1.0` decodes as `UInt64(1)` via JSONDecoder, but those
        // bytes did not round-trip through the canonical encoder
        // (which would emit `1`), so they are not canonical
        // envelope bytes.
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "1.0")
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with non-canonical exponent sequence (1e0) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeNonCanonicalExponentSequence() throws {
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "1e0")
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with leading-zero sequence (01) classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeLeadingZeroSequence() throws {
        // JSON disallows leading zeros, so this exercises the
        // malformedJSON path even though the intent is to flag
        // non-canonical sequence bytes; documented for corpus
        // governance.
        let bytes = try Self.envelopeLine(replacing: "sequence", with: "01")
        try Self.expectInteriorCorruption(bytes, classification: .malformedJSON)
    }

    @Test(
        "envelope with whitespace inside the JSON body classifies as .invalidEnvelope (non-canonical)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeWhitespaceBetweenTokens() throws {
        // The canonical encoder emits no whitespace between
        // tokens; a JSON body with intra-token whitespace is
        // valid JSON but not canonical envelope bytes.
        let canonical = try Self.canonicalLine().dropLast()
        var line = try #require(String(data: canonical, encoding: .utf8))
        line = line.replacingOccurrences(of: "\":", with: "\" :")
        let bytes = Data(line.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with uppercase-hex id classifies as .invalidEnvelope (non-canonical UUID form)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeUppercaseHexUUID() throws {
        let bytes = try Self.envelopeLine(
            replacing: "id",
            with: ##""00000000-0000-0000-0000-00000000000A""##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with un-hyphenated id classifies as .invalidEnvelope (non-canonical UUID form)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeUnhyphenatedUUID() throws {
        let bytes = try Self.envelopeLine(
            replacing: "id",
            with: ##""00000000000000000000000000000001""##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with createdAt missing milliseconds classifies as .invalidEnvelope (non-canonical RFC 3339 form)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeCreatedAtMissingMilliseconds() throws {
        let bytes = try Self.envelopeLine(
            replacing: "createdAt",
            with: ##""2023-11-14T22:13:20Z""##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with empty contentType classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeEmptyContentType() throws {
        let bytes = try Self.envelopeLine(
            replacing: "contentType",
            with: ##""""##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with whitespace inside contentType classifies as .invalidEnvelope (non-visible-ASCII byte)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeContentTypeWithWhitespace() throws {
        let bytes = try Self.envelopeLine(
            replacing: "contentType",
            with: ##""text\/plain charset""##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with hint key containing a disallowed character classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeHintKeyDisallowedCharacter() throws {
        // Hint key contains `!`, outside the allowed character set.
        let bytes = try Self.envelopeLine(
            replacing: "hints",
            with: ##"{"a!b":"x"}"##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with a hint value containing an ASCII control character classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeHintValueControlCharacter() throws {
        // `\u0001` is U+0001, an ASCII control.
        let bytes = try Self.envelopeLine(
            replacing: "hints",
            with: ##"{"a":"\u0001"}"##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with a non-string hint value classifies as .invalidEnvelope (typed-decode failure)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeHintValueNonString() throws {
        let bytes = try Self.envelopeLine(
            replacing: "hints",
            with: ##"{"a":1}"##
        )
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "envelope with an unknown extra top-level key classifies as .invalidEnvelope",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func envelopeExtraTopLevelKey() throws {
        let canonical = try Self.canonicalLine().dropLast()
        var line = try #require(String(data: canonical, encoding: .utf8))
        // Insert an extra key before the closing brace.
        let trailing = line.removeLast()
        #expect(trailing == "}")
        line.append(##","extra":1}"##)
        let bytes = Data(line.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(bytes, classification: .invalidEnvelope)
    }

    @Test(
        "interior corruption hard-stops the scan; later accepted lines are never visited",
        .tags(.lgp14, .lgp15, .lgp17, .lgp36, .lgp37)
    )
    func interiorCorruptionHardStopsLaterLines() throws {
        let url = try Self.uniqueSegmentURL()
        defer { FileLogStoreTestSupport.remove(url.deletingLastPathComponent()) }
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        // Interior corrupt line in the middle.
        let corrupt = Data("[1,2,3]".utf8) + Data([0x0A])
        let laterAccepted = try Self.canonicalLine(sequence: 2)
        try Self.writeSegment(acceptedLine + corrupt + laterAccepted, to: url)
        let handle = try Self.openHandle(url)
        defer { try? handle.close() }

        let outcomes = try RecoverablePrefixScanner.collect(
            handle: handle, segmentURL: url
        )
        // Accepted prefix is reported, corruption terminates the
        // walk, and the later accepted line is never visited.
        #expect(outcomes == [
            .accepted(byteOffset: 0, bytes: acceptedLine),
            .corrupt(byteOffset: UInt64(acceptedLine.count), classification: .nonObjectJSON)
        ])
    }
}
