import Foundation
import Loggers
import Testing

@testable import LoggerPersistence

/// Production-path coverage for the package canonical binary64
/// renderer. Every test in this suite drives
/// `LogRecordPersistentEncoder().encode(_:)` with the production
/// `CanonicalBinary64.render` (no injected renderer, no fixture
/// stand-ins) and asserts the persisted bytes match the canonical
/// shortest-roundtrip contract in `Docs/FileFormatSpec.md`.
@Suite("CanonicalBinary64 production path")
struct CanonicalBinary64ProductionPathTests {
    private static func makeRecord(
        attributes: [LogAttribute] = []
    ) -> LogRecord {
        LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .info,
            domain: "Auth",
            message: "ok",
            attributes: attributes
        )
    }

    /// Encodes the canonical test record with a single Double
    /// attribute keyed `"v"`, returning the canonical JSON payload.
    private static func encodedPayload(value: Double) throws -> String {
        let encoder = LogRecordPersistentEncoder()
        let envelope = try encoder.encode(
            makeRecord(attributes: [LogAttribute("v", value)])
        )
        return try payloadString(envelope)
    }

    /// Builds the expected canonical envelope for the test record
    /// shape when the `v` attribute renders to the given token.
    /// Pins every byte of the envelope so tests verify canonical
    /// output without parsing the encoder's response.
    private static func expectedEnvelope(valueToken: String) -> String {
        let attributesJSON = ##"[{"key":"v","value":\##(valueToken)}]"##
        let metadataJSON = ##""domain":"Auth","level":"info","message":"ok","timestamp":"2023-11-14T22:13:20.000Z""##
        return ##"{"attributes":\##(attributesJSON),\##(metadataJSON)}"##
    }

    // MARK: Boundary constants

    @Test("Greatest finite magnitude renders to canonical 17-digit scientific form")
    func greatestFiniteMagnitudeCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: Double.greatestFiniteMagnitude)
        #expect(actual == Self.expectedEnvelope(valueToken: "1.7976931348623157e308"))
    }

    @Test("Negated greatest finite magnitude carries the canonical leading minus")
    func negatedGreatestFiniteMagnitudeCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: -Double.greatestFiniteMagnitude)
        #expect(actual == Self.expectedEnvelope(valueToken: "-1.7976931348623157e308"))
    }

    @Test("Least normal magnitude renders to canonical 17-digit scientific form")
    func leastNormalMagnitudeCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: Double.leastNormalMagnitude)
        #expect(actual == Self.expectedEnvelope(valueToken: "2.2250738585072014e-308"))
    }

    @Test("Least nonzero (smallest subnormal) magnitude renders as `5e-324`")
    func leastNonzeroMagnitudeCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: Double.leastNonzeroMagnitude)
        #expect(actual == Self.expectedEnvelope(valueToken: "5e-324"))
    }

    @Test("Smallest subnormal one ULP above the minimum renders canonically")
    func leastNonzeroPlusOneUlpCanonicalBytes() throws {
        // `Double(bitPattern: 2)` is `1e-323` -- two ULPs above the
        // smallest subnormal, crossing exponent `-324` -> `-323`
        // within the subnormal class.
        let actual = try Self.encodedPayload(value: Double(bitPattern: 2))
        #expect(actual == Self.expectedEnvelope(valueToken: "1e-323"))
    }

    // MARK: Exponent boundary formatting

    @Test("Exponent value `e21` switches to scientific notation per the canonical window")
    func fixedToScientificBoundaryCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: 1e21)
        #expect(actual == Self.expectedEnvelope(valueToken: "1e21"))
    }

    @Test("Exponent value `e20` stays in fixed-point notation per the canonical window")
    func fixedPointUpperBoundaryCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: 1e20)
        #expect(actual == Self.expectedEnvelope(valueToken: "100000000000000000000"))
    }

    @Test("Exponent value `e-5` stays in fixed-point notation per the canonical window")
    func fixedPointLowerBoundaryCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: 1e-5)
        #expect(actual == Self.expectedEnvelope(valueToken: "0.00001"))
    }

    @Test("Exponent value `e-6` switches to scientific notation per the canonical window")
    func scientificLowerBoundaryCanonicalBytes() throws {
        let actual = try Self.encodedPayload(value: 1e-6)
        #expect(actual == Self.expectedEnvelope(valueToken: "1e-6"))
    }

    // MARK: Signed zero collapse

    @Test("Both `+0.0` and `-0.0` collapse to the single canonical token `0`")
    func signedZeroCollapseCanonicalBytes() throws {
        let positive = try Self.encodedPayload(value: 0.0)
        let negative = try Self.encodedPayload(value: -0.0)
        let expected = Self.expectedEnvelope(valueToken: "0")
        #expect(positive == expected)
        #expect(negative == expected)
    }

    // MARK: Negative-value coverage

    @Test(
        "Representative negative values render with the canonical leading minus",
        arguments: [
            (-1.0, "-1"),
            (-1.5, "-1.5"),
            (-0.1, "-0.1"),
            (-1e30, "-1e30"),
            (-1e-9, "-1e-9"),
            (-1.2345678901234567, "-1.2345678901234567")
        ]
    )
    func negativeValueCanonicalBytes(input: Double, expected: String) throws {
        let actual = try Self.encodedPayload(value: input)
        #expect(actual == Self.expectedEnvelope(valueToken: expected))
    }

    // MARK: Bit-pattern sweep (representative production-path coverage)

    /// Verifies that the production persistence path preserves the
    /// canonical renderer token verbatim and round-trips the original
    /// finite bit pattern.
    private static func assertSweepInvariants(bits: UInt64) throws {
        let value = Double(bitPattern: bits)
        guard let canonicalToken = CanonicalBinary64.render(value) else {
            Issue.record("CanonicalBinary64.render returned nil for finite input bits \(bits)")
            return
        }
        #expect(
            !canonicalToken.contains("E"),
            "non-canonical uppercase E in \(canonicalToken) for bits \(bits)"
        )
        #expect(
            !canonicalToken.contains("e+"),
            "non-canonical `e+` in \(canonicalToken) for bits \(bits)"
        )
        #expect(
            !canonicalToken.contains("e-0"),
            "non-canonical `e-0` in \(canonicalToken) for bits \(bits)"
        )
        #expect(
            !canonicalToken.hasPrefix("+"),
            "non-canonical leading `+` in \(canonicalToken) for bits \(bits)"
        )
        let actual = try Self.encodedPayload(value: value)
        #expect(
            actual == Self.expectedEnvelope(valueToken: canonicalToken),
            "encoder did not embed canonical token verbatim for bits \(bits)"
        )
        let isPositiveZero = bits == 0
        let isNegativeZero = bits == (UInt64(1) << 63)
        if isPositiveZero || isNegativeZero {
            // Both signed-zero bit patterns must collapse to canonical `0`.
            #expect(
                canonicalToken == "0",
                "signed-zero collapse failed for bits \(bits): \(canonicalToken)"
            )
            return
        }
        guard let parsed = Double(canonicalToken) else {
            Issue.record(
                "canonical token does not parse as Double: \(canonicalToken) (bits \(bits))"
            )
            return
        }
        #expect(
            parsed.bitPattern == value.bitPattern,
            "canonical token \(canonicalToken) round-tripped to a different bit pattern from \(bits)"
        )
    }

    @Test("Production renderer round-trips a deterministic finite-bit-pattern sweep")
    func canonicalDoubleRendererBitPatternSweep() throws {
        var state: UInt64 = 0xAB_CD_EF_01_23_45_67_89
        let count = 8000
        var processed = 0
        while processed < count {
            // Deterministic cross-platform pseudo-random sequence.
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let bits = state
            let biased = (bits >> 52) & 0x7FF
            // Reject NaN and +/-inf (biased exponent `0x7FF`); keep
            // every other bit pattern, including subnormals
            // (biased exponent `0`) and signed zero.
            if biased == 0x7FF { continue }
            try Self.assertSweepInvariants(bits: bits)
            processed += 1
        }
    }

    @Test("Production renderer round-trips every exponent class boundary with mantissa 0")
    func canonicalDoubleRendererExponentClassSweep() throws {
        // Biased exponent boundaries with mantissa 0.
        for biased in 1 ... 2046 {
            try Self.assertSweepInvariants(bits: UInt64(biased) << 52)
        }
    }

    @Test("Production renderer round-trips a representative subnormal sweep")
    func canonicalDoubleSubnormalSweep() throws {
        // Walk subnormal mantissas `1, 2, 4, ..., 2^51`
        // (biased exponent `0`, IEEE-754 subnormal class).
        var mantissa: UInt64 = 1
        while mantissa < (UInt64(1) << 52) {
            try Self.assertSweepInvariants(bits: mantissa)
            mantissa <<= 1
        }
    }
}
