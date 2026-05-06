import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// `JSONDuplicateMemberScanner` byte-level explicit duplicate
/// detection for envelope JSON objects.
@Suite("JSONDuplicateMemberScanner explicit duplicate detection")
struct JSONDuplicateMemberScannerTests {
    private static func scan(_ json: String) -> JSONDuplicateMemberScanner.Outcome {
        JSONDuplicateMemberScanner.scan(objectBody: Data(json.utf8))
    }
}

extension JSONDuplicateMemberScannerTests {
    @Test(
        "Distinct top-level keys are not flagged",
        .tags(.lgp21, .lgp38)
    )
    func distinctTopLevelKeys() {
        #expect(Self.scan(##"{"a":1,"b":2}"##) == .noDuplicate)
    }

    @Test(
        "Verbatim duplicate top-level keys are flagged",
        .tags(.lgp21, .lgp38)
    )
    func verbatimDuplicateTopLevelKeys() {
        #expect(Self.scan(##"{"a":1,"a":2}"##) == .duplicateMember)
    }

    @Test(
        "Empty object is not flagged",
        .tags(.lgp21, .lgp38)
    )
    func emptyObject() {
        #expect(Self.scan("{}") == .noDuplicate)
    }
}

extension JSONDuplicateMemberScannerTests {
    @Test(
        "Hints duplicate: verbatim duplicate hint keys are flagged",
        .tags(.lgp21, .lgp38)
    )
    func hintsDuplicateVerbatim() {
        #expect(
            Self.scan(##"{"hints":{"a":"x","a":"y"}}"##) == .duplicateMember
        )
    }

    @Test(
        "Hints duplicate: distinct hint keys are not flagged",
        .tags(.lgp21, .lgp38)
    )
    func hintsDistinct() {
        #expect(
            Self.scan(##"{"hints":{"a":"x","b":"y"}}"##) == .noDuplicate
        )
    }
}

extension JSONDuplicateMemberScannerTests {
    @Test(
        "Top-level: an escaped BMP key (\\u0061) equals its unescaped spelling (a) after JSON decoding",
        .tags(.lgp21, .lgp38)
    )
    func topLevelEscapedBMPEqualsUnescaped() {
        // The first key is the JSON escape spelling `a`,
        // which decodes to U+0061 (LATIN SMALL LETTER A); the
        // second key is the raw `a` byte.
        #expect(
            Self.scan(##"{"\u0061":1,"a":2}"##) == .duplicateMember
        )
    }

    @Test(
        "Top-level: a surrogate-pair-escaped key (\\uD83D\\uDE00) equals its raw UTF-8 spelling (😀)",
        .tags(.lgp21, .lgp38)
    )
    func topLevelSurrogatePairEqualsUTF8() {
        // `😀` is the JSON surrogate-pair escape for
        // U+1F600 GRINNING FACE; the second key uses raw UTF-8
        // bytes of the same scalar.
        #expect(
            Self.scan(##"{"\uD83D\uDE00":1,"😀":2}"##) == .duplicateMember
        )
    }

    @Test(
        "Hints: a surrogate-pair-escaped key (\\uD83D\\uDE00) equals its raw UTF-8 spelling (😀)",
        .tags(.lgp21, .lgp38)
    )
    func hintsSurrogatePairEqualsUTF8() {
        #expect(
            Self.scan(##"{"hints":{"\uD83D\uDE00":"x","😀":"y"}}"##) == .duplicateMember
        )
    }

    @Test(
        "Strict: a lone high surrogate fails escape decoding (no false-positive duplicate)",
        .tags(.lgp21, .lgp38)
    )
    func strictRejectsLoneHighSurrogate() {
        // Two `\uD83D` lone high surrogates do not falsely register
        // as duplicates; the walker fails decoding and reports no
        // duplicate, deferring malformed-JSON ruling to the wider
        // classification path.
        #expect(
            Self.scan(##"{"\uD83D":1,"\uD83D":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a lone low surrogate fails escape decoding (no false-positive duplicate)",
        .tags(.lgp21, .lgp38)
    )
    func strictRejectsLoneLowSurrogate() {
        #expect(
            Self.scan(##"{"\uDE00":1,"\uDE00":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a high surrogate followed by a non-low-surrogate \\u escape fails decoding",
        .tags(.lgp21, .lgp38)
    )
    func strictRejectsHighSurrogateWithNonLowTrailing() {
        // \uD83D followed by a (a non-low-surrogate BMP scalar)
        // is not a valid surrogate pair.
        #expect(
            Self.scan(##"{"\uD83Da":1,"\uD83Da":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Top-level: distinct non-BMP scalars are not flagged as duplicates",
        .tags(.lgp21, .lgp38)
    )
    func distinctNonBMPScalars() {
        // U+1F600 GRINNING FACE vs U+1F601 GRINNING FACE WITH SMILING EYES.
        #expect(
            Self.scan(##"{"😀":1,"😁":2}"##) == .noDuplicate
        )
    }
}

extension JSONDuplicateMemberScannerTests {
    @Test(
        "Recursive: a duplicate member inside an arbitrary nested object (not `hints`) is flagged",
        .tags(.lgp21, .lgp38)
    )
    func recursiveDuplicateInNestedObject() {
        #expect(
            Self.scan(##"{"meta":{"a":1,"a":2}}"##) == .duplicateMember
        )
    }

    @Test(
        "Recursive: a duplicate member in a deeply nested object is flagged",
        .tags(.lgp21, .lgp38)
    )
    func recursiveDuplicateInDeeplyNestedObject() {
        #expect(
            Self.scan(##"{"a":{"b":{"c":{"x":1,"x":2}}}}"##) == .duplicateMember
        )
    }

    @Test(
        "Recursive: duplicate keys inside an object element of a JSON array are flagged",
        .tags(.lgp21, .lgp38)
    )
    func recursiveDuplicateInsideArrayObjectElement() {
        #expect(
            Self.scan(##"{"items":[{"x":1,"x":2}]}"##) == .duplicateMember
        )
    }

    @Test(
        "Recursive: duplicate keys inside an array of arrays of objects are flagged",
        .tags(.lgp21, .lgp38)
    )
    func recursiveDuplicateInsideNestedArrayObject() {
        #expect(
            Self.scan(##"{"a":[[{"x":1,"x":2}]]}"##) == .duplicateMember
        )
    }

    @Test(
        "Recursive: same name in two sibling object scopes is NOT a duplicate",
        .tags(.lgp21, .lgp38)
    )
    func recursiveSiblingObjectScopesNotShared() {
        // `a` appears once per sibling object scope; member-name
        // sets are per-object, not global.
        #expect(
            Self.scan(##"{"left":{"a":1},"right":{"a":2}}"##) == .noDuplicate
        )
    }

    @Test(
        "Recursive: same name in nested vs outer object scope is NOT a duplicate",
        .tags(.lgp21, .lgp38)
    )
    func recursiveNestedAndOuterScopeNotShared() {
        // Outer `a` and inner `a` live in distinct object scopes
        // and are not duplicates of each other.
        #expect(
            Self.scan(##"{"a":{"a":1}}"##) == .noDuplicate
        )
    }

    @Test(
        "Recursive: escape vs raw equivalence is detected at nested object depth",
        .tags(.lgp21, .lgp38)
    )
    func recursiveEscapeEqualsRawInNestedObject() {
        // Inside a non-`hints` nested object, `a` (a) and
        // raw `a` decode to the same member name.
        #expect(
            Self.scan(##"{"meta":{"\u0061":1,"a":2}}"##) == .duplicateMember
        )
    }
}

extension JSONDuplicateMemberScannerTests {
    @Test(
        "Valid: keyword values true/false/null parse cleanly",
        .tags(.lgp38)
    )
    func validKeywordValues() {
        #expect(Self.scan(##"{"a":true,"b":false,"c":null}"##) == .noDuplicate)
    }

    @Test(
        "Valid: number forms (negative, decimal, exponent) parse cleanly",
        .tags(.lgp38)
    )
    func validNumberForms() {
        #expect(
            Self.scan(##"{"a":-1,"b":1.5,"c":1e10,"d":1.5E-3}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a non-keyword identifier value (truex) does not false-positive duplicate detection",
        .tags(.lgp38)
    )
    func strictRejectsNonKeywordIdentifier() {
        // `truex` is not a JSON keyword token. The walker stops
        // gracefully and reports no duplicate (callers see the
        // bytes as malformed via the wider classification path).
        #expect(
            Self.scan(##"{"a":truex,"a":1}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a keyword followed by a structural delimiter is accepted",
        .tags(.lgp38)
    )
    func strictKeywordTrailedByDelimiter() {
        #expect(Self.scan(##"{"a":true,"b":1}"##) == .noDuplicate)
    }

    @Test(
        "Strict: a number with leading zero (01) does not false-positive duplicate detection",
        .tags(.lgp38)
    )
    func strictRejectsLeadingZeroNumber() {
        #expect(
            Self.scan(##"{"a":01,"a":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a number with bare exponent letter (1e) does not false-positive",
        .tags(.lgp38)
    )
    func strictRejectsBareExponent() {
        #expect(
            Self.scan(##"{"a":1e,"a":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a number with empty fractional part (1.) does not false-positive",
        .tags(.lgp38)
    )
    func strictRejectsEmptyFraction() {
        #expect(
            Self.scan(##"{"a":1.,"a":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a bare minus sign (-) does not false-positive",
        .tags(.lgp38)
    )
    func strictRejectsBareMinus() {
        #expect(
            Self.scan(##"{"a":-,"a":2}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a non-hex byte in a unicode escape (\\u00ZZ) does not false-positive",
        .tags(.lgp38)
    )
    func strictRejectsNonHexUnicodeEscape() {
        #expect(
            Self.scan(##"{"a":"\u00ZZ","a":1}"##) == .noDuplicate
        )
    }

    @Test(
        "Strict: a raw control byte (0x01) inside a JSON string rejects parsing",
        .tags(.lgp38)
    )
    func strictRejectsRawControlByteInString() {
        var bytes = Data(##"{"a":""##.utf8)
        bytes.append(0x01)
        bytes.append(contentsOf: Data(##"","a":1}"##.utf8))
        #expect(
            JSONDuplicateMemberScanner.scan(objectBody: bytes) == .noDuplicate
        )
    }
}
