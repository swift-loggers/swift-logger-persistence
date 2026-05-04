import Foundation
import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Regression tests for scanning sliced `Data` without assuming zero-based indices.
@Suite("JSONDuplicateMemberScanner scans sliced Data")
struct JSONDuplicateMemberScannerDataTests {}

extension JSONDuplicateMemberScannerDataTests {
    @Test(
        "Scanner detects duplicate keys when the input Data is a non-zero-startIndex slice",
        .tags(.lgp34)
    )
    func duplicateDetectionOnDataSlice() {
        // Slicing produces a `Data` with non-zero `startIndex`; the
        // walker must respect the slice's index range.
        let prefix = Data("garbage-prefix-bytes".utf8)
        let body = Data(##"{"a":1,"a":2}"##.utf8)
        let combined = prefix + body
        let slice = combined.suffix(from: combined.startIndex + prefix.count)
        #expect(slice.startIndex != 0)
        #expect(JSONDuplicateMemberScanner.scan(objectBody: slice) == .duplicateMember)
    }

    @Test(
        "Scanner reports no duplicate on a clean object passed as a non-zero-startIndex slice",
        .tags(.lgp34)
    )
    func noDuplicateOnDataSlice() {
        let prefix = Data("X".utf8)
        let body = Data(##"{"a":1,"b":2}"##.utf8)
        let combined = prefix + body
        let slice = combined.suffix(from: combined.startIndex + prefix.count)
        #expect(slice.startIndex != 0)
        #expect(JSONDuplicateMemberScanner.scan(objectBody: slice) == .noDuplicate)
    }
}
