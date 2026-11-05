import Foundation

// What System.DateTimeOffset is to the C# engine: an instant with the clock offset it was written in. Two values
// are equal when they are the same instant, as in .NET; the clock fields and the offset are kept for writing the
// date out the way it was read. The range is that of .NET, 0001-01-01 to 9999-12-31 in UTC. Foundation's Date
// and Calendar are not used: they would bring the machine's time zone and calendar along.

public struct DateTimeOffset: Hashable, Comparable, CustomStringConvertible {
    private static let minSeconds = -62_135_596_800
    private static let maxSeconds = 253_402_300_799

    /// Whole seconds since 1970-01-01T00:00:00 UTC.
    private let seconds: Int

    /// 100 ns units past the whole second, 0 to 9_999_999.
    public let ticks: Int

    /// The offset of the clock from UTC, in minutes.
    public let offsetMinutes: Int

    /// Nil when a field is out of range, or the instant is outside 0001-01-01 to 9999-12-31 in UTC.
    public init?(valid year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, ticks: Int = 0, offsetMinutes: Int = 0) {
        guard year >= 1, year <= 9999, month >= 1, month <= 12, day >= 1, day <= Self.daysIn(year, month),
              hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59,
              ticks >= 0, ticks < 10_000_000, abs(offsetMinutes) <= 14 * 60 else { return nil }
        let local = Self.daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second
        let utc = local - offsetMinutes * 60
        guard utc >= Self.minSeconds, utc <= Self.maxSeconds else { return nil }
        seconds = utc
        self.ticks = ticks
        self.offsetMinutes = offsetMinutes
    }

    private init(seconds: Int, ticks: Int, offsetMinutes: Int) {
        self.seconds = seconds
        self.ticks = ticks
        self.offsetMinutes = offsetMinutes
    }

    /// The same clock `count` seconds later; nil when that is outside the range.
    public func addSeconds(_ count: Int) -> DateTimeOffset? {
        let (sum, overflow) = seconds.addingReportingOverflow(count)
        guard !overflow, sum >= Self.minSeconds, sum <= Self.maxSeconds else { return nil }
        return DateTimeOffset(seconds: sum, ticks: ticks, offsetMinutes: offsetMinutes)
    }

    /// A value outside the range is a caller's mistake, as the ArgumentOutOfRangeException of the C#.
    public init(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, offsetMinutes: Int = 0) {
        guard let value = DateTimeOffset(valid: year, month, day, hour, minute, second, offsetMinutes: offsetMinutes) else {
            preconditionFailure("The date or its offset is out of range.")
        }
        self = value
    }

    private var local: (year: Int, month: Int, day: Int, secondOfDay: Int) {
        let shifted = seconds + offsetMinutes * 60
        let days = Self.floorDiv(shifted, 86_400)
        let (y, m, d) = Self.civilFromDays(days)
        return (y, m, d, shifted - days * 86_400)
    }

    public var year: Int { local.year }
    public var month: Int { local.month }
    public var day: Int { local.day }
    public var hour: Int { local.secondOfDay / 3600 }
    public var minute: Int { local.secondOfDay % 3600 / 60 }
    public var second: Int { local.secondOfDay % 60 }

    public static func == (a: DateTimeOffset, b: DateTimeOffset) -> Bool {
        a.seconds == b.seconds && a.ticks == b.ticks
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(seconds)
        hasher.combine(ticks)
    }

    public static func < (a: DateTimeOffset, b: DateTimeOffset) -> Bool {
        a.seconds != b.seconds ? a.seconds < b.seconds : a.ticks < b.ticks
    }

    /// 2026-10-19T21:30:05.0000000+03:00, the round-trip form of .NET.
    public var description: String {
        let sign = offsetMinutes < 0 ? "-" : "+"
        return String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%07ld", year, month, day, hour, minute, second, ticks)
            + sign + String(format: "%02ld:%02ld", abs(offsetMinutes) / 60, abs(offsetMinutes) % 60)
    }

    static func daysIn(_ year: Int, _ month: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        switch month {
        case 2: return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return a % b < 0 ? q - 1 : q
    }

    // Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
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
}
