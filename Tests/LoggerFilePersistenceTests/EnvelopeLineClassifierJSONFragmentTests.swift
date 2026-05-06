import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression coverage for JSON fragment classification.
@Suite("EnvelopeLineClassifier JSON fragment classification")
struct EnvelopeLineClassifierJSONFragmentTests {
    private static func classify(_ string: String) -> EnvelopeLineClassifier.Outcome {
        EnvelopeLineClassifier.classify(Data(string.utf8) + Data([0x0A]))
    }
}

extension EnvelopeLineClassifierJSONFragmentTests {
    @Test(
        "JSON fragment `true` classifies as .nonObjectJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func trueFragmentClassifiesAsNonObjectJSON() {
        #expect(Self.classify("true") == .corrupt(.nonObjectJSON))
    }

    @Test(
        "JSON fragment `null` classifies as .nonObjectJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func nullFragmentClassifiesAsNonObjectJSON() {
        #expect(Self.classify("null") == .corrupt(.nonObjectJSON))
    }

    @Test(
        "JSON fragment `123` classifies as .nonObjectJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func numberFragmentClassifiesAsNonObjectJSON() {
        #expect(Self.classify("123") == .corrupt(.nonObjectJSON))
    }

    @Test(
        "JSON fragment `\"abc\"` classifies as .nonObjectJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func stringFragmentClassifiesAsNonObjectJSON() {
        #expect(Self.classify(##""abc""##) == .corrupt(.nonObjectJSON))
    }

    @Test(
        "JSON fragment `[]` classifies as .nonObjectJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func emptyArrayFragmentClassifiesAsNonObjectJSON() {
        #expect(Self.classify("[]") == .corrupt(.nonObjectJSON))
    }

    @Test(
        "Empty JSON object classifies as .invalidEnvelope",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func emptyObjectProceedsToEnvelopeValidation() {
        #expect(Self.classify("{}") == .corrupt(.invalidEnvelope))
    }

    @Test(
        "Genuine JSON syntax error classifies as .malformedJSON",
        .tags(.lgp17, .lgp33, .lgp35)
    )
    func malformedJSONClassifiesAsMalformedJSON() {
        #expect(Self.classify("{ invalid") == .corrupt(.malformedJSON))
    }
}
