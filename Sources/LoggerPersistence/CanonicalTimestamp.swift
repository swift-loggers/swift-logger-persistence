import Foundation

/// Single source of truth for the canonical RFC 3339 UTC
/// millisecond timestamp profile.
///
/// Defined by `Docs/FileFormatSpec.md` ("Timestamp Field"). This
/// type centralizes validation and rendering so the timestamp
/// profile stays consistent across the package's wire-format
/// surfaces. Exposed via the `WireFormat` SPI so the file-backed
/// store can emit byte-identical timestamps without duplicating
/// the canonical profile.
@_spi(WireFormat) public enum CanonicalTimestamp {
    /// Decomposed Gregorian + UTC components of a renderable
    /// canonical RFC 3339 UTC millisecond timestamp. `millisecond`
    /// is in `0...999`, including for pre-reference
    /// (negative-interval) dates.
    @_spi(WireFormat) public struct Components: Sendable, Equatable {
        @_spi(WireFormat) public let year: Int
        @_spi(WireFormat) public let month: Int
        @_spi(WireFormat) public let day: Int
        @_spi(WireFormat) public let hour: Int
        @_spi(WireFormat) public let minute: Int
        @_spi(WireFormat) public let second: Int
        @_spi(WireFormat) public let millisecond: Int
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
    @_spi(WireFormat) public static func components(of date: Date) -> Components? {
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

    /// Returns the canonical RFC 3339 UTC millisecond rendering of
    /// `date`, or `nil` if the date is outside the canonical
    /// profile.
    ///
    /// The rendering shape is exactly
    /// `YYYY-MM-DDTHH:MM:SS.mmmZ` (POSIX locale, Gregorian
    /// calendar, fixed millisecond fractional precision, literal
    /// `Z`). Bytes participate in replay identity and are emitted
    /// independently of any Foundation formatter.
    @_spi(WireFormat) public static func canonicalString(from date: Date) -> String? {
        guard let parts = components(of: date) else { return nil }
        var output = ""
        output.reserveCapacity(24)
        appendZeroPadded(parts.year, width: 4, into: &output)
        output.append("-")
        appendZeroPadded(parts.month, width: 2, into: &output)
        output.append("-")
        appendZeroPadded(parts.day, width: 2, into: &output)
        output.append("T")
        appendZeroPadded(parts.hour, width: 2, into: &output)
        output.append(":")
        appendZeroPadded(parts.minute, width: 2, into: &output)
        output.append(":")
        appendZeroPadded(parts.second, width: 2, into: &output)
        output.append(".")
        appendZeroPadded(parts.millisecond, width: 3, into: &output)
        output.append("Z")
        return output
    }

    private static let asciiDigit: [Unicode.Scalar] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
    ]

    /// Appends `value` as a zero-padded fixed-width decimal ASCII
    /// sequence. Inputs are non-negative because every component
    /// returned by ``components(of:)`` is non-negative.
    private static func appendZeroPadded(
        _ value: Int,
        width: Int,
        into output: inout String
    ) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(width)
        var remaining = value
        repeat {
            scalars.append(asciiDigit[remaining % 10])
            remaining /= 10
        } while remaining > 0
        while scalars.count < width {
            scalars.append(asciiDigit[0])
        }
        for scalar in scalars.reversed() {
            output.unicodeScalars.append(scalar)
        }
    }
}
