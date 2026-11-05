import Foundation

// Twin of windows/LazyPDF.Core/Structure/PdfDate.cs: PDF dates (ISO 32000-1 7.9.4), "D:20261019213005+03'00'", and
// the XMP form of the same. Formatting after Lazy Scan's PdfA.cs (PdfDate, XmpDate, Offset).
//
// `parseXmp` reads the ISO 8601 forms of XMP (ISO 16684-1) where the C# calls DateTimeOffset.TryParse, which also
// takes free text such as "March 1, 2026" or "3/1/2026"; those read as nil here.

public enum PdfDate {
    /// Reads a PDF date; every part after the year may be missing. A date without a zone counts as UTC. Nil when it is not a date.
    public static func parse(_ text: String?) -> DateTimeOffset? {
        guard let text else { return nil }
        var s = Array(trimmed(text).unicodeScalars)
        if s.count >= 2 && s[0] == "D" && s[1] == ":" { s.removeFirst(2) }
        var at = 0
        func take(_ digits: Int, _ fallback: Int) -> Int {
            if at + digits > s.count { return fallback }
            var value = 0
            for i in 0..<digits {
                let v = s[at + i].value
                if v < 0x30 || v > 0x39 { return fallback }
                value = value * 10 + Int(v - 0x30)
            }
            at += digits
            return value
        }

        let year = take(4, -1)
        let month = take(2, 1), day = take(2, 1), hour = take(2, 0), minute = take(2, 0), second = take(2, 0)
        if year < 1 || month < 1 || month > 12 || hour > 23 || minute > 59 || second > 60 { return nil }
        if day < 1 || day > DateTimeOffset.daysIn(year, month) { return nil }

        var offset = 0
        if at < s.count && (s[at] == "+" || s[at] == "-") {
            let sign = s[at] == "-" ? -1 : 1
            at += 1
            let zoneHours = take(2, 0)
            if at < s.count && s[at] == "'" { at += 1 }
            let zoneMinutes = take(2, 0)
            if zoneHours > 23 || zoneMinutes > 59 { return nil }
            offset = sign * (zoneHours * 60 + zoneMinutes)
        }
        if abs(offset) > 14 * 60 { return nil }
        // new DateTimeOffset throws when the instant is outside 0001 to 9999 in UTC (0001-01-01 at +05:00); that reads as nil here.
        return DateTimeOffset(valid: year, month, day, hour, minute, Swift.min(second, 59), offsetMinutes: offset)
    }

    /// "D:20261019213005+03'00'".
    public static func format(_ date: DateTimeOffset) -> String {
        "D:" + String(format: "%04ld%02ld%02ld%02ld%02ld%02ld", date.year, date.month, date.day, date.hour, date.minute, date.second)
            + offset(date.offsetMinutes, "'") + "'"
    }

    /// "2026-10-19T21:30:05+03:00".
    public static func formatXmp(_ date: DateTimeOffset) -> String {
        String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld", date.year, date.month, date.day, date.hour, date.minute, date.second)
            + offset(date.offsetMinutes, ":")
    }

    /// Reads an XMP date; a date without a zone counts as UTC.
    public static func parseXmp(_ text: String?) -> DateTimeOffset? {
        guard let text else { return nil }
        var reader = XmpDateReader(Array(trimmed(text).unicodeScalars))
        return reader.read()
    }

    /// What `string.Trim()` removes: the characters `char.IsWhiteSpace` accepts.
    static func trimmed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end && scalars[start].properties.isWhitespace { start += 1 }
        while end > start && scalars[end - 1].properties.isWhitespace { end -= 1 }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[start..<end])
        return String(result)
    }

    private static func offset(_ minutes: Int, _ separator: String) -> String {
        (minutes < 0 ? "-" : "+") + String(format: "%02ld", abs(minutes) / 60) + separator + String(format: "%02ld", abs(minutes) % 60)
    }
}

// Year, month, optional day, optional time with seconds and a fraction, optional zone, all of it ISO 8601.
private struct XmpDateReader {
    private let s: [Unicode.Scalar]
    private var at = 0

    init(_ scalars: [Unicode.Scalar]) {
        s = scalars
    }

    private var done: Bool { at >= s.count }

    private func isDigit(_ i: Int) -> Bool { i < s.count && s[i].value >= 0x30 && s[i].value <= 0x39 }

    private func isSpace(_ i: Int) -> Bool { i < s.count && s[i].properties.isWhitespace }

    private mutating func digits(_ least: Int, _ most: Int) -> Int? {
        var value = 0, n = 0
        while n < most && isDigit(at) {
            value = value * 10 + Int(s[at].value - 0x30)
            at += 1
            n += 1
        }
        return n >= least ? value : nil
    }

    private mutating func accept(_ c: Unicode.Scalar) -> Bool {
        if at < s.count && s[at] == c {
            at += 1
            return true
        }
        return false
    }

    mutating func read() -> DateTimeOffset? {
        guard let year = digits(4, 4), accept("-"), let month = digits(1, 2) else { return nil }
        var day = 1
        if accept("-") {
            guard let d = digits(1, 2) else { return nil }
            day = d
        }
        var hour = 0, minute = 0, second = 0, ticks = 0
        var carry = false
        var hasTime = false
        if accept("T") || accept("t") {
            guard let h = digits(2, 2), accept(":"), let m = digits(2, 2) else { return nil }
            (hour, minute) = (h, m)
            hasTime = true
        } else if isSpace(at) {
            let start = at
            while isSpace(at) { at += 1 }
            if isDigit(at) {
                guard let h = digits(1, 2), accept(":"), let m = digits(2, 2) else { return nil }
                (hour, minute) = (h, m)
                hasTime = true
            } else {
                at = start
            }
        }
        if hasTime && accept(":") {
            guard let sec = digits(2, 2) else { return nil }
            second = sec
            if accept(".") || accept(",") {
                guard let t = fraction() else { return nil }
                // A fraction that rounds up to the next second carries into the clock, as in .NET.
                carry = t == 10_000_000
                ticks = carry ? 0 : t
            }
        }
        var offset = 0
        while isSpace(at) { at += 1 }
        if accept("Z") || accept("z") {
            offset = 0
        } else if !done {
            guard let o = zone() else { return nil }
            offset = o
        }
        if !done || abs(offset) > 14 * 60 { return nil }
        guard let date = DateTimeOffset(valid: year, month, day, hour, minute, second, ticks: ticks, offsetMinutes: offset) else { return nil }
        return carry ? date.addSeconds(1) : date
    }

    // The digits after the point as 100 ns units: the seventh is the last kept, the eighth rounds.
    private mutating func fraction() -> Int? {
        var units = 0, n = 0, next = 0
        while isDigit(at) {
            let d = Int(s[at].value - 0x30)
            if n < 7 {
                units = units * 10 + d
            } else if n == 7 {
                next = d
            }
            n += 1
            at += 1
        }
        if n == 0 { return nil }
        for _ in Swift.min(n, 7)..<7 { units *= 10 }
        return next >= 5 ? units + 1 : units
    }

    // +h, +hh, +hh:mm, +h:m and +hhmm.
    private mutating func zone() -> Int? {
        let sign: Int
        if accept("+") {
            sign = 1
        } else if accept("-") {
            sign = -1
        } else {
            return nil
        }
        let start = at
        guard let first = digits(1, 4) else { return nil }
        let count = at - start
        var hours = first, minutes = 0
        if accept(":") {
            if count > 2 { return nil }
            guard let m = digits(1, 2) else { return nil }
            minutes = m
        } else if count == 4 {
            hours = first / 100
            minutes = first % 100
        } else if count == 3 {
            return nil
        }
        if minutes > 59 { return nil }
        return sign * (hours * 60 + minutes)
    }
}
