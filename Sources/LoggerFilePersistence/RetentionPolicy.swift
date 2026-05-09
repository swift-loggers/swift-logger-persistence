/// Retention policy for ``FileLogStore``.
///
/// Retention deletes whole rotated segments after a successful append
/// admits a complete accepted line. The active writer segment is
/// never deleted. Rotation policies other than `.bySize` make every
/// retention policy a no-op because there is only one unrotated
/// segment to consider and prefix compaction is owned by the
/// removal lifecycle.
///
/// Segment topology and retention are policy contracts, not part of
/// the portable wire-format contract per the file-format
/// specification.
public struct RetentionPolicy: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case unlimited
        case maxSegments(count: Int)
        case maxTotalBytes(bytes: Int)
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Disables retention deletion. Segment topology grows as
    /// rotation produces new segments.
    public static let unlimited = RetentionPolicy(kind: .unlimited)

    /// Keeps at most `count` regular rotated segments under
    /// ``RotationPolicy/bySize(maxSegmentBytes:)``. Older rotated
    /// segments are deleted from oldest first; the active writer
    /// segment is never deleted.
    ///
    /// - Throws: ``FileLogStoreConfigurationError/invalidRetentionPolicy``
    ///   when `count` is below `1`. A retention cap of zero would
    ///   require deleting the active writer segment to satisfy the
    ///   bound, which retention is forbidden from doing.
    public static func maxSegments(
        _ count: Int
    ) throws(FileLogStoreConfigurationError) -> RetentionPolicy {
        guard count >= 1 else {
            throw .invalidRetentionPolicy
        }
        return RetentionPolicy(kind: .maxSegments(count: count))
    }

    /// Keeps the newest regular rotated segments whose total
    /// on-disk size fits `bytes` under
    /// ``RotationPolicy/bySize(maxSegmentBytes:)``. Older rotated
    /// segments are deleted from oldest first until the cap fits or
    /// only the active writer segment remains.
    ///
    /// This is a segment-retention topology limit, not a replay/export
    /// byte-limit guarantee.
    ///
    /// - Throws: ``FileLogStoreConfigurationError/invalidRetentionPolicy``
    ///   when `bytes` is below ``FileLogStore/maxEncodedLineBytes``.
    ///   A canonical line that fits the encoded-line cap must be
    ///   admittable into a fresh empty segment; a smaller cap would
    ///   force retention to consider deleting a segment containing
    ///   the line that just admitted it.
    public static func maxTotalBytes(
        _ bytes: Int
    ) throws(FileLogStoreConfigurationError) -> RetentionPolicy {
        guard bytes >= FileLogStore.maxEncodedLineBytes else {
            throw .invalidRetentionPolicy
        }
        return RetentionPolicy(kind: .maxTotalBytes(bytes: bytes))
    }
}
