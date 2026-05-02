import Foundation
import Loggers
import Testing

@testable import LoggerPersistence

@Suite("LogRecordPersistentEncoder")
struct LogRecordPersistentEncoderTests {
    private static func makeRecord(
        level: LoggerLevel = .info,
        domain: LoggerDomain = "Auth",
        message: LogMessage = "ok",
        attributes: [LogAttribute] = []
    ) -> LogRecord {
        LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: level,
            domain: domain,
            message: message,
            attributes: attributes
        )
    }

    // Payload decoding helper lives in `PayloadStringHelper.swift`
    // and is shared with `LogRecordPersistentEncoderDateTests`.

    // MARK: Sequence

    @Test("Encoder assigns monotonic sequence on each call starting at 1")
    func sequenceIsMonotonic() throws {
        let encoder = LogRecordPersistentEncoder()
        var sequences: [UInt64] = []
        for _ in 0 ..< 5 {
            let envelope = try encoder.encode(Self.makeRecord())
            sequences.append(envelope.sequence)
        }
        #expect(sequences == [1, 2, 3, 4, 5])
    }

    @Test("Encoder assigns a contiguous, unique sequence range across concurrent encodes")
    func concurrentEncodesProduceContiguousSequenceRange() async throws {
        let encoder = LogRecordPersistentEncoder()
        let count = 100
        let sequences: [UInt64] = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    let envelope = try encoder.encode(Self.makeRecord())
                    return envelope.sequence
                }
            }
            var collected: [UInt64] = []
            for try await sequence in group {
                collected.append(sequence)
            }
            return collected
        }
        #expect(sequences.sorted() == Array(1 ... UInt64(count)))
    }

    @Test("Encoder fails closed before emitting reserved sequence 0 on wrap")
    func sequenceWrapFailsClosed() throws {
        // Park the cursor at the last valid sequence value so the next
        // encode succeeds and the one after that exhausts the counter.
        let encoder = LogRecordPersistentEncoder(initialSequence: UInt64.max)

        let lastValid = try encoder.encode(Self.makeRecord())
        #expect(lastValid.sequence == UInt64.max)

        #expect(throws: LogRecordPersistentEncoderError.sequenceExhausted) {
            try encoder.encode(Self.makeRecord())
        }

        // Repeat: subsequent calls keep failing with the same error
        // rather than silently resuming at 1.
        #expect(throws: LogRecordPersistentEncoderError.sequenceExhausted) {
            try encoder.encode(Self.makeRecord())
        }
    }

    @Test("Encoder rejects an envelope whose attribute is a non-finite Double")
    func nonFiniteDoubleIsRejected() throws {
        let encoder = LogRecordPersistentEncoder()
        for nonFinite in [Double.infinity, -.infinity, .nan] {
            #expect(throws: LogRecordPersistentEncoderError.nonFiniteDoubleAttribute) {
                try encoder.encode(
                    Self.makeRecord(attributes: [LogAttribute("ratio", nonFinite)])
                )
            }
        }
    }

    // MARK: Redaction

    @Test("Encoder redacts private message segments before writing")
    func privateMessageSegmentRedacted() throws {
        let encoder = LogRecordPersistentEncoder()
        let username = "alice"
        let envelope = try encoder.encode(
            Self.makeRecord(
                message: "User \(username, privacy: .private) signed in"
            )
        )
        let payload = try payloadString(envelope)
        #expect(payload.contains(#""message":"User <private> signed in""#))
        #expect(!payload.contains("alice"))
    }

    @Test("Encoder redacts sensitive attribute values before writing")
    func sensitiveAttributeRedacted() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(
                attributes: [LogAttribute("token", "secret", privacy: .sensitive)]
            )
        )
        let payload = try payloadString(envelope)
        #expect(payload.contains(#""key":"token","value":"<redacted>""#))
        #expect(!payload.contains("secret"))
    }

    @Test("Private attribute value is redacted but preserved as a typed string")
    func privateAttributeRedactedAsString() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(
                attributes: [LogAttribute("user", "alice", privacy: .private)]
            )
        )
        let payload = try payloadString(envelope)
        #expect(payload.contains(#""key":"user","value":"<private>""#))
        #expect(!payload.contains("alice"))
    }

    @Test("Encoder preserves typed LogValue for public attributes")
    func publicAttributesPreserveTypedLogValue() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(
                attributes: [
                    LogAttribute("active", true),
                    LogAttribute("count", 42),
                    LogAttribute("meta", LogValue.object(["k": .integer(1)])),
                    LogAttribute("ratio", 1.5),
                    LogAttribute("tags", LogValue.array([.string("a"), .string("b")]))
                ]
            )
        )
        let payload = try payloadString(envelope)
        // Public attributes preserve their typed JSON shape rather
        // than collapsing to strings.
        #expect(payload.contains(#""key":"active","value":true"#))
        #expect(payload.contains(#""key":"count","value":42"#))
        #expect(payload.contains(#""key":"meta","value":{"k":1}"#))
        #expect(payload.contains(#""key":"ratio","value":1.5"#))
        #expect(payload.contains(#""key":"tags","value":["a","b"]"#))
    }

    // MARK: Hints and content type

    @Test("Encoder populates hints with level and domain")
    func hintsContainLevelAndDomain() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(level: .error, domain: "Network")
        )
        #expect(envelope.hints["level"] == "error")
        #expect(envelope.hints["domain"] == "Network")
    }

    @Test("Encoder uses the spec-locked content type")
    func contentTypeMatchesSpec() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(Self.makeRecord())
        #expect(envelope.contentType == LogRecordPersistentEncoder.contentType)
        #expect(envelope.contentType == "application/vnd.swift-logger.record-redacted.v1+json")
    }

    // MARK: Canonical payload bytes

    @Test("Encoder emits canonical JSON bytes per FileFormatSpec")
    func canonicalPayloadBytes() throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(
                attributes: [
                    // Solidus must be emitted as `\/`.
                    LogAttribute("path", "/v1/users"),
                    // Object value forces recursive sorted-key
                    // ordering: `b` must appear before `z` in the
                    // encoded bytes even though the dictionary literal
                    // declares `z` first.
                    LogAttribute(
                        "meta",
                        LogValue.object(["z": .integer(2), "b": .integer(1)])
                    )
                ]
            )
        )
        let actual = try payloadString(envelope)
        // The expected line is a single canonical JSON object; build
        // it via concatenation so each source line stays inside the
        // line-length limit.
        let expected =
            #"{"attributes":[{"key":"path","value":"\/v1\/users"},"# +
            #"{"key":"meta","value":{"b":1,"z":2}}],"domain":"Auth","# +
            #""level":"info","message":"ok","timestamp":"2023-11-14T22:13:20.000Z"}"#
        #expect(actual == expected)
    }

    @Test(
        "Canonical Double rendering matches the FileFormatSpec binary64 profile",
        arguments: [
            // (LogValue.double input, expected encoded substring)
            // Whole-number doubles drop `.0`.
            (1.0, #""value":1"#),
            (100.0, #""value":100"#),
            (-1.0, #""value":-1"#),
            // Both `+0.0` and `-0.0` canonicalize to `0`.
            (0.0, #""value":0"#),
            (-0.0, #""value":0"#),
            // Significant fractional digits survive.
            (1.5, #""value":1.5"#),
            (0.1, #""value":0.1"#),
            // Positive exponent: `+` sign is stripped.
            (1e30, #""value":1e30"#),
            (1.5e30, #""value":1.5e30"#),
            // Negative exponent: leading zero in the magnitude is
            // stripped (Swift prints `1e-06`).
            (1e-6, #""value":1e-6"#),
            (1e-9, #""value":1e-9"#),
            // Multi-digit exponents are preserved verbatim.
            (1e-100, #""value":1e-100"#),
            (1e100, #""value":1e100"#)
        ]
    )
    func canonicalDoubleRendering(input: Double, expected: String) throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(attributes: [LogAttribute("v", input)])
        )
        let actual = try payloadString(envelope)
        #expect(actual.contains(expected), "rendering of \(input) missing \(expected) in \(actual)")
        // Shared negative checks for canonical exponent and positive-value spelling.
        #expect(!actual.contains(#""value":+"#))
        #expect(!actual.contains("e+"))
        #expect(!actual.contains("e-0"))
    }

    @Test(
        "Canonical Double rendering covers binary64 edge inputs",
        arguments: [
            // Powers of ten on both sides of the
            // fixed-point / scientific threshold
            // (`decExp < -5 || decExp >= 21`).
            (10.0, #""value":10"#),
            (1000.0, #""value":1000"#),
            (1e15, #""value":1000000000000000"#),
            (1e20, #""value":100000000000000000000"#),
            (1e21, #""value":1e21"#),
            (1e-1, #""value":0.1"#),
            (1e-4, #""value":0.0001"#),
            (1e-5, #""value":0.00001"#),
            // Negative variants exercise the leading `-` path.
            (-0.1, #""value":-0.1"#),
            // High-precision value: the canonical profile preserves
            // all 17 significant digits when needed for round-trip.
            (1.2345678901234567, #""value":1.2345678901234567"#),
            // `Double.ulpOfOne` is exactly `2.220446049250313e-16`
            // in the canonical profile.
            (Double.ulpOfOne, #""value":2.220446049250313e-16"#),
            // Smallest positive subnormal; canonical shortest spelling is `5e-324`.
            (Double.leastNonzeroMagnitude, #""value":5e-324"#)
        ]
    )
    func canonicalDoubleEdgeCases(input: Double, expected: String) throws {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(attributes: [LogAttribute("v", input)])
        )
        let actual = try payloadString(envelope)
        #expect(
            actual.contains(expected),
            "rendering of \(input) missing \(expected) in \(actual)"
        )
        #expect(!actual.contains("e+"))
        #expect(!actual.contains("e-0"))
    }

    @Test(
        "Canonical Double rendering covers boundary finite magnitudes byte-canonically",
        arguments: [
            (Double.greatestFiniteMagnitude, #""value":1.7976931348623157e308"#),
            (-Double.greatestFiniteMagnitude, #""value":-1.7976931348623157e308"#),
            (Double.leastNormalMagnitude, #""value":2.2250738585072014e-308"#),
            (-Double.leastNormalMagnitude, #""value":-2.2250738585072014e-308"#),
            (Double.leastNonzeroMagnitude, #""value":5e-324"#),
            (-Double.leastNonzeroMagnitude, #""value":-5e-324"#)
        ]
    )
    func canonicalDoubleBoundaryByteCanonical(input: Double, expected: String) throws {
        // Boundary finite magnitudes preserve canonical bytes and round-trip.
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            Self.makeRecord(attributes: [LogAttribute("v", input)])
        )
        let actual = try payloadString(envelope)
        #expect(
            actual.contains(expected),
            "rendering of \(input) missing \(expected) in \(actual)"
        )
        #expect(!actual.contains("e+"))
        #expect(!actual.contains("e-0"))
        guard let canonicalToken = CanonicalBinary64.render(input) else {
            Issue.record("CanonicalBinary64.render returned nil for finite input \(input)")
            return
        }
        guard let parsed = Double(canonicalToken) else {
            Issue.record("canonical token does not parse as Double: \(canonicalToken)")
            return
        }
        #expect(parsed == input)
    }

    @Test("Encoder error type exposes the unsupportedLogValueCase fail-closed value")
    func unsupportedLogValueCaseIsPublic() {
        // Public error case remains available for future unsupported LogValue cases.
        let error = LogRecordPersistentEncoderError.unsupportedLogValueCase
        #expect(error == .unsupportedLogValueCase)
    }

    @Test("Encoder error type exposes the canonicalRendererFailure fail-closed value")
    func canonicalRendererFailureIsPublic() {
        // Public error case remains available for canonical renderer consistency failures.
        let error = LogRecordPersistentEncoderError.canonicalRendererFailure
        #expect(error == .canonicalRendererFailure)
    }

    // Date coverage lives in `LogRecordPersistentEncoderDateTests.swift`.
}
