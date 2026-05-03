import Foundation

/// Single source of truth for the canonical RFC 3339 UTC
/// millisecond timestamp profile.
///
/// Defined by `Docs/FileFormatSpec.md` ("Timestamp Field"). This
/// type centralizes validation and rendering so the timestamp
/// profile stays consistent.
enum CanonicalTimestamp {
    /// Decomposed Gregorian + UTC components of a renderable
    /// canonical RFC 3339 UTC millisecond timestamp. `millisecond`
    /// is in `0...999`, including for pre-reference
    /// (negative-interval) dates.
    struct Components: Sendable, Equatable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let millisecond: Int
    }

    /// Validates `date` against the canonical profile and returns
    /// its Gregorian + UTC components ready for formatting.
    ///
    /// A date is renderable when:
    ///
    /// - the underlying time interval is finite,
    /// - it is millisecond-aligned,
    /// - it decomposes through Gregorian + UTC into year, month,
    ///   day, hour, minute, and second,
    /// - the rendered timestamp is in the AD era,
    /// - the rendered year is in `1...9999`.
    ///
    /// Returns `nil` for any date that fails one of these checks.
    static func components(of date: Date) -> Components? {
        let interval = date.timeIntervalSinceReferenceDate
        guard interval.isFinite else { return nil }
        let candidateMillisDouble = (interval * 1000).rounded(.toNearestOrAwayFromZero)
        guard candidateMillisDouble.isFinite else { return nil }
        guard let candidateMillis = Int64(exactly: candidateMillisDouble) else {
            return nil
        }
        // Absorbs Date construction rounding without accepting
        // non-millisecond-aligned values.
        let reconstructed = Double(candidateMillis) / 1000.0
        let tolerance = max(interval.ulp, reconstructed.ulp)
        guard abs(interval - reconstructed) <= tolerance else { return nil }
        let canonicalDate = Date(timeIntervalSinceReferenceDate: reconstructed)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let raw = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second],
            from: canonicalDate
        )
        guard let era = raw.era,
              let year = raw.year,
              let month = raw.month,
              let day = raw.day,
              let hour = raw.hour,
              let minute = raw.minute,
              let second = raw.second
        else {
            return nil
        }
        guard era == 1, (1 ... 9999).contains(year) else { return nil }
        // Floor keeps milliseconds non-negative for negative intervals.
        let floorSeconds = Int64(reconstructed.rounded(.down))
        let millisecond = Int(candidateMillis - floorSeconds * 1000)
        return Components(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            millisecond: millisecond
        )
    }
}
