import Foundation
import LazyPDFKit

// The engine keeps the conversions between its dates and Foundation's to itself; the panels need two of them.

enum PanelDates {
    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func now() -> DateTimeOffset {
        let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return DateTimeOffset(c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                              offsetMinutes: TimeZone.current.secondsFromGMT() / 60)
    }

    static func date(_ time: DateTimeOffset) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: time.offsetMinutes * 60) ?? .current
        let parts = DateComponents(year: time.year, month: time.month, day: time.day, hour: time.hour, minute: time.minute, second: time.second)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }
}
