import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Pairs an accepted prefix line with each interior-corruption shape
/// to confirm the prefix is reported and the corrupt line terminates
/// the scan.
extension RecoverablePrefixScannerTests {
    @Test(
        "an accepted line followed by a malformed JSON line yields prefix then terminal .corrupt(.malformedJSON)",
        .tags(.lgp14, .lgp17, .lgp35, .lgp36, .lgp37)
    )
    func acceptedPrefixThenMalformedJSONHardStops() throws {
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        // Unterminated JSON string.
        let corrupt = Data(##"{"a":"b"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(
            acceptedLine + corrupt,
            classification: .malformedJSON,
            expectedByteOffset: UInt64(acceptedLine.count)
        )
    }

    @Test(
        "an accepted line followed by a duplicate top-level key yields prefix then .corrupt(.duplicateJSONMember)",
        .tags(.lgp14, .lgp17, .lgp34, .lgp35, .lgp36, .lgp37)
    )
    func acceptedPrefixThenDuplicateTopLevelHardStops() throws {
        let acceptedLine = try Self.canonicalLine(sequence: 1)
        let corrupt = Data(##"{"sequence":1,"sequence":2}"##.utf8) + Data([0x0A])
        try Self.expectInteriorCorruption(
            acceptedLine + corrupt,
            classification: .duplicateJSONMember,
            expectedByteOffset: UInt64(acceptedLine.count)
        )
    }
}
