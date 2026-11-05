import Foundation

// No C# file: what CultureInfo and DateTimeOffset.ToString(format, culture) give the date token of a header or footer.
// The custom format letters are .NET's (d, f, F, g, h, H, K, m, M, s, t, y, z, the separators, quotes, backslash and %). A
// repeat of h, H, m or s past two reads as two, as in .NET, and a one-letter format is always a standard one.
// Differences: month and day names are English, or Turkish for a "tr" culture, and any other culture reads as English with
// the invariant separators. The one-letter standard formats d D f F g G m M t T y Y use the patterns of tr-TR and of en-US
// (also "en"), and the invariant ones for every other culture. U is refused, as .NET refuses it for a DateTimeOffset.

public struct CultureInfo: Equatable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public static let invariantCulture = CultureInfo("")

    fileprivate var isTurkish: Bool { name == "tr" || name.hasPrefix("tr-") }

    fileprivate var patterns: DatePatterns {
        if isTurkish {
            return DatePatterns(shortDate: "d.MM.yyyy", longDate: "d MMMM yyyy dddd", shortTime: "HH:mm", longTime: "HH:mm:ss",
                                monthDay: "d MMMM", yearMonth: "MMMM yyyy")
        }
        if name == "en" || name == "en-US" {
            return DatePatterns(shortDate: "M/d/yyyy", longDate: "dddd, MMMM d, yyyy", shortTime: "h:mm tt", longTime: "h:mm:ss tt",
                                monthDay: "MMMM d", yearMonth: "MMMM yyyy")
        }
        return DatePatterns(shortDate: "MM/dd/yyyy", longDate: "dddd, dd MMMM yyyy", shortTime: "HH:mm", longTime: "HH:mm:ss",
                            monthDay: "MMMM dd", yearMonth: "yyyy MMMM")
    }
}

private struct DatePatterns {
    let shortDate: String
    let longDate: String
    let shortTime: String
    let longTime: String
    let monthDay: String
    let yearMonth: String
}

/// The C# FormatException, for a format .NET refuses.
struct FormatException: Error {}

private enum Names {
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]
    static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static let turkishMonths = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim",
                                "Kasım", "Aralık"]
    static let turkishShortMonths = ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"]
    static let turkishDays = ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"]
    static let turkishShortDays = ["Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"]
}

extension DateTimeOffset {
    func toString(_ format: String, _ culture: CultureInfo) throws -> String {
        let patterns = culture.patterns
        // An empty format is the general pattern and the offset, for a DateTimeOffset.
        if format.isEmpty { return try custom(Array((patterns.shortDate + " " + patterns.longTime + " zzz").unicodeScalars), culture) }
        // .NET counts UTF-16 units, so a lone supplementary character is a custom format, not a standard one.
        guard format.utf16.count == 1, let letter = format.unicodeScalars.first else {
            return try custom(Array(format.unicodeScalars), culture)
        }
        switch letter {
        case "r", "R": return try inUtc().custom(Array("ddd, dd MMM yyyy HH':'mm':'ss 'GMT'".unicodeScalars), .invariantCulture)
        case "u": return try inUtc().custom(Array("yyyy'-'MM'-'dd HH':'mm':'ss'Z'".unicodeScalars), .invariantCulture)
        default: return try custom(try Self.standard(letter, patterns), culture)
        }
    }

    private static func standard(_ letter: Unicode.Scalar, _ p: DatePatterns) throws -> [Unicode.Scalar] {
        let pattern: String
        switch letter {
        case "d": pattern = p.shortDate
        case "D": pattern = p.longDate
        case "f": pattern = p.longDate + " " + p.shortTime
        case "F": pattern = p.longDate + " " + p.longTime
        case "g": pattern = p.shortDate + " " + p.shortTime
        case "G": pattern = p.shortDate + " " + p.longTime
        case "m", "M": pattern = p.monthDay
        case "t": pattern = p.shortTime
        case "T": pattern = p.longTime
        case "y", "Y": pattern = p.yearMonth
        case "s": pattern = "yyyy'-'MM'-'dd'T'HH':'mm':'ss"
        case "o", "O": pattern = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffffK"
        default: throw FormatException()
        }
        return Array(pattern.unicodeScalars)
    }

    // The same instant on the UTC clock. The offset is at most 14 hours, so the day moves by at most one.
    private func inUtc() throws -> DateTimeOffset {
        var (y, m, d) = (year, month, day)
        var minutes = hour * 60 + minute - offsetMinutes
        if minutes < 0 {
            minutes += 1440
            d -= 1
            if d < 1 {
                m -= 1
                if m < 1 { m = 12; y -= 1 }
                d = Self.daysIn(y, m)
            }
        } else if minutes >= 1440 {
            minutes -= 1440
            d += 1
            if d > Self.daysIn(y, m) {
                d = 1
                m += 1
                if m > 12 { m = 1; y += 1 }
            }
        }
        guard let value = DateTimeOffset(valid: y, m, d, minutes / 60, minutes % 60, second, ticks: ticks) else { throw FormatException() }
        return value
    }

    private func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
    }

    private var dayOfWeek: Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        return (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7
    }

    private func custom(_ f: [Unicode.Scalar], _ culture: CultureInfo) throws -> String {
        var out = ""
        try custom(f, culture, into: &out)
        return out
    }

    private func custom(_ f: [Unicode.Scalar], _ culture: CultureInfo, into out: inout String) throws {
        let turkish = culture.isTurkish
        var i = 0
        while i < f.count {
            let c = f[i]
            var n = 1
            while i + n < f.count && f[i + n] == c { n += 1 }
            switch c {
            case "d":
                if n <= 2 { out += pad(day, n) }
                else if n == 3 { out += (turkish ? Names.turkishShortDays : Names.shortDays)[dayOfWeek] }
                else { out += (turkish ? Names.turkishDays : Names.days)[dayOfWeek] }
            case "f", "F":
                if n > 7 { throw FormatException() }
                var digits = pad(ticks, 7)
                digits = String(digits.prefix(n))
                if c == "F" {
                    while digits.hasSuffix("0") { digits.removeLast() }
                    if digits.isEmpty && out.unicodeScalars.last == "." { out.unicodeScalars.removeLast() }
                }
                out += digits
            case "g": out += turkish ? "MS" : "A.D."
            case "h": out += pad(hour % 12 == 0 ? 12 : hour % 12, Swift.min(n, 2))
            case "H": out += pad(hour, Swift.min(n, 2))
            case "K":
                n = 1
                out += offsetText(colon: true, hourWidth: 2)
            case "m": out += pad(minute, Swift.min(n, 2))
            case "M":
                if n <= 2 { out += pad(month, n) }
                else if n == 3 { out += (turkish ? Names.turkishShortMonths : Names.shortMonths)[month - 1] }
                else { out += (turkish ? Names.turkishMonths : Names.months)[month - 1] }
            case "s": out += pad(second, Swift.min(n, 2))
            case "t":
                let designator = hour < 12 ? (turkish ? "ÖÖ" : "AM") : (turkish ? "ÖS" : "PM")
                out += n == 1 ? String(designator.prefix(1)) : designator
            case "y":
                out += n <= 2 ? pad(year % 100, n) : pad(year, n)
            case "z": out += offsetText(colon: n >= 3, hourWidth: n == 1 ? 1 : 2, minutes: n >= 3)
            case ":": n = 1; out += ":"
            case "/": n = 1; out += turkish ? "." : "/"
            case "\"", "'":
                n = 1
                i += 1
                var closed = false
                while i < f.count {
                    if f[i] == c { closed = true; break }
                    if f[i] == "\\" {
                        i += 1
                        if i >= f.count { throw FormatException() }
                    }
                    out.unicodeScalars.append(f[i])
                    i += 1
                }
                if !closed { throw FormatException() }
            case "%":
                n = 1
                guard i + 1 < f.count, f[i + 1] != "%" else { throw FormatException() }
                try custom([f[i + 1]], culture, into: &out)
                i += 1
            case "\\":
                n = 1
                guard i + 1 < f.count else { throw FormatException() }
                i += 1
                out.unicodeScalars.append(f[i])
            default:
                n = 1
                out.unicodeScalars.append(c)
            }
            i += n
        }
    }

    private func offsetText(colon: Bool, hourWidth: Int, minutes: Bool = true) -> String {
        let sign = offsetMinutes < 0 ? "-" : "+"
        let hours = pad(abs(offsetMinutes) / 60, hourWidth)
        return minutes ? sign + hours + (colon ? ":" : "") + pad(abs(offsetMinutes) % 60, 2) : sign + hours
    }
}
