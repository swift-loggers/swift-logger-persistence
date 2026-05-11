import Darwin
import Foundation

extension FileLogStore {
    /// Enforces ``RetentionPolicy`` after a successful append has
    /// admitted one complete accepted line. Runs while the calling
    /// `append` still holds the nonreentrant operation boundary so
    /// concurrent `append`, `flush`, `exportLogs(to:)`, and
    /// `removeExportedLogs()` callers wait until enforcement
    /// completes.
    ///
    /// Retention deletes whole rotated segments only. The active
    /// writer segment is never deleted. `.unlimited` retention and
    /// `.never` rotation are no-ops.
    ///
    /// Failure semantics: a deletion failure surfaces as
    /// `.operationFailed(.enforceRetention, url: <segment>,
    /// context: ...)`. The triggering append remains admitted and
    /// the remaining segment topology is left in a state every
    /// later append/flush/export/remove path can recover from.
    /// Directory-entry durability after unlink is best-effort.
    internal func enforceRetention() throws(FileLogStoreError) {
        switch (configuration.retention.kind, configuration.rotation.kind) {
        case (.unlimited, _), (_, .never):
            return
        case let (.maxSegments(count), .bySize):
            try enforceMaxSegments(count: count)
        case let (.maxTotalBytes(bytes), .bySize):
            try enforceMaxTotalBytes(cap: UInt64(bytes))
        case let (.maxAge(seconds), .bySize):
            try enforceMaxAge(seconds: seconds)
        }
    }

    /// Deletes oldest rotated segments until at most `count`
    /// regular rotated segments remain. The active writer segment
    /// is never selected for deletion.
    private func enforceMaxSegments(count: Int) throws(FileLogStoreError) {
        guard let root = writerRoot else { return }
        let segments = try enumerateRotatedSegmentsForRetention(root: root)
        // `segments` total includes active under `.bySize`; deletion
        // keeps active and trims oldest non-active until total ≤ count.
        let excess = segments.count - count
        guard excess > 0 else { return }
        let candidates = segments.filter { !isActiveSegment(at: $0.url) }
        let toDelete = candidates.prefix(min(excess, candidates.count))
        for entry in toDelete {
            try unlinkRetentionEntry(rootFD: root.rootFD, url: entry.url)
        }
    }

    /// Deletes oldest rotated segments until total on-disk segment
    /// bytes fit `cap` or only the active writer segment remains.
    /// Selection runs through ``RetentionMaxTotalBytesSelection``
    /// so the arithmetic is overflow-safe regardless of externally
    /// modified or sparse segment sizes (no global sum, no
    /// saturating subtraction).
    private func enforceMaxTotalBytes(cap: UInt64) throws(FileLogStoreError) {
        guard let root = writerRoot else { return }
        let segments = try enumerateRotatedSegmentsForRetention(root: root)
        var sized: [RetentionMaxTotalBytesSelection.Candidate] = []
        sized.reserveCapacity(segments.count)
        for entry in segments {
            let metadata = try readRegularRetentionSegmentMetadata(
                rootFD: root.rootFD, url: entry.url
            )
            sized.append(
                RetentionMaxTotalBytesSelection.Candidate(
                    url: entry.url,
                    size: metadata.size,
                    isActive: isActiveSegment(at: entry.url)
                )
            )
        }
        let toDelete = RetentionMaxTotalBytesSelection.segmentsToDelete(
            candidates: sized, cap: cap
        )
        for url in toDelete {
            try unlinkRetentionEntry(rootFD: root.rootFD, url: url)
        }
    }

    /// Deletes rotated segments whose modification time is at least
    /// `seconds` older than the current wall-clock. The active
    /// writer segment is never selected for deletion, even when it
    /// would otherwise qualify by age.
    ///
    /// Source of truth is `fstatat(AT_SYMLINK_NOFOLLOW)` `st_mtimespec`
    /// on each candidate; the policy does not parse envelope
    /// payloads or accepted-line timestamps. Candidates are
    /// deleted oldest-mtime first, with sequence ascending as the
    /// deterministic tie-break inherited from the enumerator.
    private func enforceMaxAge(seconds: Int64) throws(FileLogStoreError) {
        guard let root = writerRoot else { return }
        let segments = try enumerateRotatedSegmentsForRetention(root: root)
        let nowSeconds = (nowForRetentionTesting?() ?? Date()).timeIntervalSince1970
        // Production `Date()` is finite; a test clock seam that
        // returns a non-finite value would silently no-op age
        // selection (any NaN comparison is false). Fail loudly
        // so the test misconfiguration surfaces.
        guard nowSeconds.isFinite else {
            throw .operationFailed(
                operation: .enforceRetention,
                url: configuration.directory,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "retention clock returned non-finite seconds"
                )
            )
        }
        let cap = TimeInterval(seconds)
        var aged: [AgedSegment] = []
        aged.reserveCapacity(segments.count)
        for entry in segments {
            if isActiveSegment(at: entry.url) { continue }
            let metadata = try readRegularRetentionSegmentMetadata(
                rootFD: root.rootFD, url: entry.url
            )
            if nowSeconds - metadata.mtime >= cap {
                aged.append(AgedSegment(
                    url: entry.url,
                    sequence: entry.sequence,
                    mtime: metadata.mtime
                ))
            }
        }
        // Deterministic order comes from the comparator, not from
        // Swift `sort(by:)` stability guarantees: `mtime` ascending
        // with `sequence` ascending as the tie-break breaks every
        // equal-mtime pair to the lower-sequence segment.
        aged.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
            return lhs.sequence < rhs.sequence
        }
        for entry in aged {
            try unlinkRetentionEntry(rootFD: root.rootFD, url: entry.url)
        }
    }

    private func enumerateRotatedSegmentsForRetention(
        root: SegmentRoot
    ) throws(FileLogStoreError) -> [(url: URL, sequence: UInt64)] {
        do throws(InternalReadError) {
            return try root.enumerateRotatedSegments()
        } catch {
            throw FileLogStoreError(projecting: error, onto: .enforceRetention)
        }
    }

    /// Reads regular-file metadata for a retention candidate without
    /// following symlinks.
    private func readRegularRetentionSegmentMetadata(
        rootFD: Int32, url: URL
    ) throws(FileLogStoreError) -> RetentionSegmentMetadata {
        let leaf = url.lastPathComponent
        var statBuf = stat()
        let result = leaf.withCString { cName in
            fstatat(rootFD, cName, &statBuf, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .enforceRetention,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "retention candidate metadata read failed"
                )
            )
        }
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
            throw .operationFailed(
                operation: .enforceRetention,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "retention candidate is not a regular file"
                )
            )
        }
        guard statBuf.st_size >= 0 else {
            throw .operationFailed(
                operation: .enforceRetention,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "retention candidate reported negative size"
                )
            )
        }
        let mtimeSeconds = Double(statBuf.st_mtimespec.tv_sec)
            + Double(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000
        return RetentionSegmentMetadata(
            size: UInt64(statBuf.st_size),
            mtime: mtimeSeconds
        )
    }

    /// Revalidates and deletes one retention candidate under the held root.
    private func unlinkRetentionEntry(
        rootFD: Int32, url: URL
    ) throws(FileLogStoreError) {
        try fireBeforeRetentionUnlinkSeam(url: url)
        _ = try readRegularRetentionSegmentMetadata(rootFD: rootFD, url: url)
        let leaf = url.lastPathComponent
        let result = leaf.withCString { cName in
            Darwin.unlinkat(rootFD, cName, 0)
        }
        if result != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .enforceRetention,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "retention segment deletion failed"
                )
            )
        }
    }

    private func fireBeforeRetentionUnlinkSeam(
        url: URL
    ) throws(FileLogStoreError) {
        guard let testSeam = onBeforeRetentionUnlinkForTesting else { return }
        do {
            try testSeam(url)
        } catch {
            throw .operationFailed(
                operation: .enforceRetention,
                url: url,
                context: FileSystemErrorContext(from: error)
            )
        }
    }
}

private struct RetentionSegmentMetadata {
    let size: UInt64
    /// Modification time as seconds since the Unix epoch with
    /// nanosecond precision, sourced from `fstatat(AT_SYMLINK_NOFOLLOW)`.
    let mtime: TimeInterval
}

/// One `.maxAge` deletion candidate paired with its modification
/// time so age-ascending sort can survive equal-mtime ties via the
/// enumerator's sequence-ascending order.
private struct AgedSegment {
    let url: URL
    let sequence: UInt64
    let mtime: TimeInterval
}

/// Pure selection helper for `RetentionPolicy.maxTotalBytes(cap)`.
///
/// Walks candidates newest → oldest. The active writer segment is
/// always retained regardless of size; older non-active candidates
/// are retained while each fits the running headroom `cap -
/// retainedTotal`. Once a non-active candidate cannot fit, it and
/// every older candidate are returned in oldest-first deletion
/// order.
///
/// Arithmetic is overflow-safe by construction: there is no global
/// sum across all candidate sizes (so a single oversized or sparse
/// segment cannot trap or wrap a `UInt64` total) and no saturating
/// subtraction; the running `headroom` only ever decreases by
/// segments that were already proven to fit, so the additions used
/// to update it are bounded by `cap` and cannot overflow.
internal enum RetentionMaxTotalBytesSelection {
    /// One candidate segment paired with its on-disk size and
    /// active-writer flag. `url` is treated as opaque.
    internal struct Candidate: Sendable, Equatable {
        let url: URL
        let size: UInt64
        let isActive: Bool
    }

    /// Returns segment URLs to delete under `cap` in oldest-first
    /// order. Inputs are expected in numeric-sequence ascending
    /// order with the active writer segment as the highest-sequence
    /// entry; the helper does not assume more than that.
    static func segmentsToDelete(
        candidates: [Candidate],
        cap: UInt64
    ) -> [URL] {
        var headroom = cap
        // Index of the oldest retained candidate (inclusive).
        // Default `candidates.count` means no candidate has been retained yet.
        var firstRetainedIndex = candidates.count
        for index in candidates.indices.reversed() {
            let entry = candidates[index]
            if entry.isActive {
                firstRetainedIndex = index
                // Active is always retained, even when its size
                // exceeds `cap`. Clamp headroom at zero so older
                // non-active candidates do not falsely qualify.
                headroom = entry.size >= headroom ? 0 : headroom - entry.size
                continue
            }
            if entry.size <= headroom {
                firstRetainedIndex = index
                headroom -= entry.size
                continue
            }
            // This candidate does not fit; deletion contains this
            // entry and every older entry (newest-first priority).
            break
        }
        return candidates[..<firstRetainedIndex].map(\.url)
    }
}
