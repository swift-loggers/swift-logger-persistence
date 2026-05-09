import Foundation
import Testing

@testable import LoggerFilePersistence

/// Pure-helper coverage for ``RetentionMaxTotalBytesSelection``.
///
/// Exercises the overflow-safe newest-first selection contract
/// against synthetic `UInt64` sizes: arbitrary input shapes,
/// pathological `UInt64.max` sparse-segment sizes, and the
/// boundary case where the active segment alone is larger than
/// the cap. The production `.maxTotalBytes` path maps descriptor
/// metadata into this helper and never sums sizes outside it.
@Suite("RetentionPolicy maxTotalBytes selection")
struct RetentionSelectionTests {
    /// Synthetic root used to mint candidate URLs through the
    /// production filename helper rather than a test-side shadow
    /// padding scheme.
    private static let syntheticRoot = URL(fileURLWithPath: "/seg")

    private static func candidate(
        sequence: UInt64, size: UInt64, isActive: Bool = false
    ) -> RetentionMaxTotalBytesSelection.Candidate {
        let url = SegmentEnumeration.rotatedSegmentURL(
            in: syntheticRoot, sequence: sequence, minimumWidth: 6
        )
        return RetentionMaxTotalBytesSelection.Candidate(
            url: url, size: size, isActive: isActive
        )
    }
}

// MARK: - Empty / trivial

extension RetentionSelectionTests {
    @Test(
        "Empty candidate list yields empty deletion list",
        .tags(.lgp7)
    )
    func emptyCandidates() {
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: [], cap: 1024
        )
        #expect(toDelete.isEmpty)
    }

    @Test(
        "Only the active segment is always retained, regardless of cap",
        .tags(.lgp7)
    )
    func onlyActiveAlwaysRetained() {
        let active = Self.candidate(sequence: 1, size: 999, isActive: true)
        // Cap below active size still keeps active.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: [active], cap: 100
        )
        #expect(toDelete.isEmpty)
    }
}

// MARK: - Newest-first contiguous suffix

extension RetentionSelectionTests {
    @Test(
        "All candidates fit cap → no deletion",
        .tags(.lgp7)
    )
    func allFitNoDeletion() {
        let candidates = [
            Self.candidate(sequence: 1, size: 100),
            Self.candidate(sequence: 2, size: 100),
            Self.candidate(sequence: 3, size: 100, isActive: true)
        ]
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 1000
        )
        #expect(toDelete.isEmpty)
    }

    @Test(
        "Cap forces oldest-first deletion until headroom fits",
        .tags(.lgp7)
    )
    func capForcesOldestDeletion() {
        let candidates = [
            Self.candidate(sequence: 1, size: 500),
            Self.candidate(sequence: 2, size: 300),
            Self.candidate(sequence: 3, size: 200, isActive: true)
        ]
        // cap = 600. Active 200 retained → headroom 400.
        // Older 300 fits → retained → headroom 100.
        // Oldest 500 does not fit → drop it (and any older).
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 600
        )
        #expect(
            toDelete == [URL(fileURLWithPath: "/seg/log.000001.ndjson")]
        )
    }

    @Test(
        "Mid-segment exceeds cap → that segment and all older are dropped",
        .tags(.lgp7)
    )
    func midSegmentExceedsCap() {
        // Even though the oldest is small, the newest-first
        // priority drops it once a newer candidate cannot fit.
        let candidates = [
            Self.candidate(sequence: 1, size: 10),
            Self.candidate(sequence: 2, size: 10000),
            Self.candidate(sequence: 3, size: 50),
            Self.candidate(sequence: 4, size: 50, isActive: true)
        ]
        // cap = 200. Active 50 → headroom 150. seg3 50 → headroom 100.
        // seg2 10_000 → drop. seg1 10 fits headroom but newer-first
        // dropped → also drop.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 200
        )
        #expect(toDelete == [
            URL(fileURLWithPath: "/seg/log.000001.ndjson"),
            URL(fileURLWithPath: "/seg/log.000002.ndjson")
        ])
    }

    @Test(
        "Boundary: candidate size exactly equals headroom retains the candidate",
        .tags(.lgp7)
    )
    func boundaryEqualToHeadroomRetains() {
        let candidates = [
            Self.candidate(sequence: 1, size: 100),
            Self.candidate(sequence: 2, size: 100, isActive: true)
        ]
        // cap = 200. Active 100 → headroom 100. seg1 size 100 →
        // 100 ≤ 100 → retained, headroom 0.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 200
        )
        #expect(toDelete.isEmpty)
    }

    @Test(
        "Boundary: candidate size exceeds headroom by one drops it",
        .tags(.lgp7)
    )
    func boundaryAboveHeadroomDrops() {
        let candidates = [
            Self.candidate(sequence: 1, size: 101),
            Self.candidate(sequence: 2, size: 100, isActive: true)
        ]
        // cap = 200. Active 100 → headroom 100. seg1 size 101 →
        // 101 > 100 → drop.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 200
        )
        #expect(
            toDelete == [URL(fileURLWithPath: "/seg/log.000001.ndjson")]
        )
    }
}

// MARK: - Active oversized

extension RetentionSelectionTests {
    @Test(
        "Active size larger than cap clamps headroom to zero and drops every older candidate",
        .tags(.lgp7)
    )
    func activeOversizedDropsAllOlder() {
        let candidates = [
            Self.candidate(sequence: 1, size: 1),
            Self.candidate(sequence: 2, size: 1),
            Self.candidate(sequence: 3, size: UInt64.max, isActive: true)
        ]
        // Active alone exceeds cap → headroom 0. Older 1-byte
        // segments cannot fit headroom of 0 → both dropped.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 1024
        )
        #expect(toDelete == [
            URL(fileURLWithPath: "/seg/log.000001.ndjson"),
            URL(fileURLWithPath: "/seg/log.000002.ndjson")
        ])
    }

    @Test(
        "Active size equal to cap keeps active and drops every older candidate",
        .tags(.lgp7)
    )
    func activeEqualToCapDropsAllOlder() {
        let candidates = [
            Self.candidate(sequence: 1, size: 1),
            Self.candidate(sequence: 2, size: 100, isActive: true)
        ]
        // Active exactly equals cap → headroom 0 (size >= headroom
        // path). Older drops.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 100
        )
        #expect(
            toDelete == [URL(fileURLWithPath: "/seg/log.000001.ndjson")]
        )
    }
}

// MARK: - Overflow safety on UInt64.max sizes

extension RetentionSelectionTests {
    @Test(
        "Pathological UInt64.max segment sizes do not trap the selection",
        .tags(.lgp2, .lgp7)
    )
    func uint64MaxSegmentSizesDoNotTrap() {
        let candidates = [
            Self.candidate(sequence: 1, size: UInt64.max),
            Self.candidate(sequence: 2, size: UInt64.max),
            Self.candidate(sequence: 3, size: UInt64.max),
            Self.candidate(sequence: 4, size: 10, isActive: true)
        ]
        // No global sum is computed — a `reduce(+)` over these
        // sizes would trap on overflow. The helper must walk
        // newest-first and drop everything older than active.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 1000
        )
        #expect(toDelete == [
            URL(fileURLWithPath: "/seg/log.000001.ndjson"),
            URL(fileURLWithPath: "/seg/log.000002.ndjson"),
            URL(fileURLWithPath: "/seg/log.000003.ndjson")
        ])
    }

    @Test(
        "Cap = UInt64.max retains every candidate without saturating subtraction",
        .tags(.lgp2, .lgp7)
    )
    func capUInt64MaxRetainsAllCandidates() {
        let candidates = [
            Self.candidate(sequence: 1, size: 1),
            Self.candidate(sequence: 2, size: 1),
            Self.candidate(sequence: 3, size: 1, isActive: true)
        ]
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: UInt64.max
        )
        #expect(toDelete.isEmpty)
    }

    @Test(
        "Sparse segment claiming UInt64.max size larger than cap is dropped without trap",
        .tags(.lgp2, .lgp7)
    )
    func sparseOldSegmentDoesNotTrap() {
        let candidates = [
            Self.candidate(sequence: 1, size: UInt64.max),
            Self.candidate(sequence: 2, size: 10),
            Self.candidate(sequence: 3, size: 10, isActive: true)
        ]
        // cap = 100. Active 10 → headroom 90. seg2 10 → headroom 80.
        // seg1 UInt64.max → does not fit → drop.
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: candidates, cap: 100
        )
        #expect(
            toDelete == [URL(fileURLWithPath: "/seg/log.000001.ndjson")]
        )
    }
}
