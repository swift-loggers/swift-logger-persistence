import Foundation

/// Shared test fixture for year-9999 `Date` construction at the
/// upper edge of the canonical RFC 3339 millisecond profile.
enum Year9999DateFixture {
    /// Builds `9999-12-31T23:59:59 UTC` with the given `millisecond`
    /// of the second and optional `microsecondOffset` (in microseconds
    /// relative to that millisecond). Returns `nil` if the requested
    /// sub-second offset falls outside `0..<1_000_000_000` nanoseconds
    /// or if Calendar rejects the resulting components.
    static func lastSecond(
        millisecond: Int,
        microsecondOffset: Int = 0
    ) -> Date? {
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let nanoseconds = millisecond * 1_000_000 + microsecondOffset * 1000
        guard (0 ..< 1_000_000_000).contains(nanoseconds) else { return nil }
        var components = DateComponents()
        components.year = 9999
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        components.second = 59
        components.nanosecond = nanoseconds
        return calendar.date(from: components)
    }
}
