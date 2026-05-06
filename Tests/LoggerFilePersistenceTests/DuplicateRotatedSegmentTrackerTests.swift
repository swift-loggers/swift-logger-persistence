import LoggerPersistenceTestSupport
import Testing

@testable import LoggerFilePersistence

/// Order-independence regression coverage for duplicate rotated-segment diagnostics.
@Suite("DuplicateRotatedSegmentTracker order-independence")
struct DuplicateRotatedSegmentTrackerTests {
    /// Three lex-distinct spellings of sequence 1, ordered:
    /// `log.0000001.ndjson` < `log.000001.ndjson` < `log.1.ndjson`.
    private static let spellingsForSequence1 = [
        "log.0000001.ndjson",
        "log.000001.ndjson",
        "log.1.ndjson"
    ]

    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for index in items.indices {
            var rest = items
            let element = rest.remove(at: index)
            for permutation in permutations(rest) {
                result.append([element] + permutation)
            }
        }
        return result
    }
}

extension DuplicateRotatedSegmentTrackerTests {
    @Test(
        "firstDuplicate is insertion-order independent",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func firstDuplicateIsLexLowestPair() {
        let permutations = Self.permutations(Self.spellingsForSequence1)
        #expect(permutations.count == 6)
        for permutation in permutations {
            var tracker = DuplicateRotatedSegmentTracker()
            for name in permutation {
                tracker.observe(sequence: 1, name: name)
            }
            let duplicate = tracker.firstDuplicate()
            #expect(duplicate?.sequence == 1)
            #expect(duplicate?.first == "log.0000001.ndjson")
            #expect(duplicate?.second == "log.000001.ndjson")
        }
    }

    @Test(
        "firstDuplicate reports the smallest numeric sequence with a duplicate spelling",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func firstDuplicateIsSmallestSequenceWithDuplicate() {
        var tracker = DuplicateRotatedSegmentTracker()
        // Sequence 5 duplicates first; sequence 2 must still win numerically.
        tracker.observe(sequence: 5, name: "log.5.ndjson")
        tracker.observe(sequence: 5, name: "log.000005.ndjson")
        tracker.observe(sequence: 2, name: "log.2.ndjson")
        tracker.observe(sequence: 2, name: "log.000002.ndjson")

        let duplicate = tracker.firstDuplicate()
        #expect(duplicate?.sequence == 2)
        #expect(duplicate?.first == "log.000002.ndjson")
        #expect(duplicate?.second == "log.2.ndjson")
    }

    @Test(
        "firstDuplicate returns nil when no sequence has more than one spelling",
        .tags(.lgp6)
    )
    func firstDuplicateReturnsNilWithoutDuplicate() {
        var tracker = DuplicateRotatedSegmentTracker()
        tracker.observe(sequence: 1, name: "log.000001.ndjson")
        tracker.observe(sequence: 2, name: "log.000002.ndjson")
        tracker.observe(sequence: 3, name: "log.000003.ndjson")
        #expect(tracker.firstDuplicate() == nil)
    }

    @Test(
        "firstDuplicate discards spellings larger than the second-smallest",
        .tags(.lgp2, .lgp6, .lgp39)
    )
    func discardsSpellingsLargerThanSecondSmallest() {
        // Lex order: log.0001.ndjson < log.001.ndjson
        //          < log.01.ndjson  < log.1.ndjson.
        // Insert in arbitrary order; the lex-smallest pair must
        // win regardless.
        var tracker = DuplicateRotatedSegmentTracker()
        tracker.observe(sequence: 1, name: "log.001.ndjson")
        tracker.observe(sequence: 1, name: "log.0001.ndjson")
        tracker.observe(sequence: 1, name: "log.1.ndjson")
        tracker.observe(sequence: 1, name: "log.01.ndjson")

        let duplicate = tracker.firstDuplicate()
        #expect(duplicate?.first == "log.0001.ndjson")
        #expect(duplicate?.second == "log.001.ndjson")
    }

    @Test(
        "maxSequence tracks the largest sequence observed regardless of insertion order",
        .tags(.lgp6, .lgp39)
    )
    func maxSequenceTracksMaximumIndependentOfOrder() {
        var tracker = DuplicateRotatedSegmentTracker()
        #expect(tracker.maxSequence == nil)

        tracker.observe(sequence: 1, name: "log.1.ndjson")
        #expect(tracker.maxSequence == 1)

        tracker.observe(sequence: 5, name: "log.5.ndjson")
        #expect(tracker.maxSequence == 5)

        tracker.observe(sequence: 3, name: "log.3.ndjson")
        #expect(tracker.maxSequence == 5)

        tracker.observe(sequence: 7, name: "log.7.ndjson")
        #expect(tracker.maxSequence == 7)
    }
}
