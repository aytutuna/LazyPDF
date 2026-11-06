import Foundation

// No C# twin: the conversions a certificate, a time stamp or a CMS date needs and DateTimeOffset (Structure) keeps
// private. They go through the clock fields, so they do not depend on the machine's time zone.

extension DateTimeOffset {
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return a % b < 0 ? q - 1 : q
    }

    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// Whole seconds since 1970-01-01T00:00:00 UTC.
    var unixSeconds: Int {
        Self.daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offsetMinutes * 60
    }

    /// nil when the instant is outside 0001 to 9999.
    init?(unixSeconds: Int, ticks: Int = 0, offsetMinutes: Int = 0) {
        let local = unixSeconds + offsetMinutes * 60
        let days = Self.floorDiv(local, 86_400)
        let rest = local - days * 86_400
        let (y, m, d) = Self.civilFromDays(days)
        self.init(valid: y, m, d, rest / 3600, rest % 3600 / 60, rest % 60, ticks: ticks, offsetMinutes: offsetMinutes)
    }

    /// The same instant written at offset 0.
    var utc: DateTimeOffset {
        DateTimeOffset(unixSeconds: unixSeconds, ticks: ticks) ?? self
    }

    func adding(seconds: Int) -> DateTimeOffset? {
        DateTimeOffset(unixSeconds: unixSeconds + seconds, ticks: ticks, offsetMinutes: offsetMinutes)
    }

    func adding(days: Int) -> DateTimeOffset? { adding(seconds: days * 86_400) }

    func adding(minutes: Int) -> DateTimeOffset? { adding(seconds: minutes * 60) }

    /// DateTimeOffset.AddYears: the same month and day, the last day of the month when that is missing.
    func adding(years: Int) -> DateTimeOffset? {
        let target = year + years
        let lastDay = Self.daysIn(target, month)
        return DateTimeOffset(valid: target, month, min(day, lastDay), hour, minute, second, ticks: ticks, offsetMinutes: offsetMinutes)
    }
}

/// The clock of the machine in UTC, for a verification that was given no time.
func currentTime() -> DateTimeOffset {
    let t = Date().timeIntervalSince1970
    let whole = Int(t.rounded(.down))
    return DateTimeOffset(unixSeconds: whole, ticks: Int((t - Double(whole)) * 10_000_000)) ?? DateTimeOffset(1970, 1, 1, 0, 0, 0)
}
