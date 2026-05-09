/// Segment-rotation policy for ``FileLogStore``.
///
/// Segment naming, rotation boundaries, and retention are policy
/// contracts, not part of the portable wire-format contract per the
/// file-format specification.
public struct RotationPolicy: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case never
        case bySize(maxSegmentBytes: Int)
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Writes every accepted line into a single segment file
    /// while this policy is used.
    public static let never = RotationPolicy(kind: .never)

    /// Rotates to a new segment when the current segment's size
    /// plus the next append unit's encoded size would exceed
    /// `maxSegmentBytes`.
    ///
    /// - Throws: ``FileLogStoreConfigurationError/invalidRotationPolicy``
    ///   when `maxSegmentBytes` is below
    ///   ``FileLogStore/maxEncodedLineBytes``. A canonical line
    ///   that fits the encoded-line cap must also fit a fresh
    ///   empty segment; a smaller cap would admit lines that no
    ///   segment could hold.
    public static func bySize(
        maxSegmentBytes: Int
    ) throws(FileLogStoreConfigurationError) -> RotationPolicy {
        guard maxSegmentBytes >= FileLogStore.maxEncodedLineBytes else {
            throw .invalidRotationPolicy
        }
        return RotationPolicy(kind: .bySize(maxSegmentBytes: maxSegmentBytes))
    }
}

/// Configuration validation failures raised by ``RotationPolicy``
/// and ``RetentionPolicy`` factories.
public enum FileLogStoreConfigurationError: Error, Sendable, Equatable {
    /// The requested segment cap is below
    /// ``FileLogStore/maxEncodedLineBytes``.
    case invalidRotationPolicy
    /// The requested retention bound is below its policy lower limit.
    case invalidRetentionPolicy
}
