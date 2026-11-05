import Foundation

// No C# twin: what FormFunctions.cs gets from DateTime.TryParseExact and DateTime.TryParse under the invariant culture with
// AllowWhiteSpaces, for the patterns the AF date and time functions use. TryParse of anything else is a short list of
// further patterns here (ISO 8601, day and month names), not the whole of .NET's grammar.

struct ScriptDate {
    var year = 1
    var month = 1
    var day = 1
    var hour = 0
    var minute = 0
    var second = 0

    /// 0 for Sunday.
    var dayOfWeek: Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        return (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7
    }
}

enum FormDates {
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private enum Token {
        case day(Int), month(Int), year(Int), hour24(Int), hour12(Int), minute(Int), second(Int), designator
        case literal(UInt16)
        case space
    }

    // The patterns of ParseDate(text), in .NET custom format syntax.
    private static let patterns = [
        "M/d/yyyy", "M/d/yy", "M/d", "d-MMM-yy", "d-MMM-yyyy", "yyyy-MM-dd", "yy-MM-dd", "MMM-yy", "MMMM-yy", "MMM d, yyyy", "MMMM d, yyyy",
        "M/d/yy h:mm tt", "M/d/yy H:mm", "M/d/yyyy h:mm tt", "M/d/yyyy H:mm", "H:mm", "h:mm tt", "H:mm:ss", "h:mm:ss tt", "d.M.yyyy", "dd.MM.yyyy",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/M/d", "d MMM yyyy", "d MMMM yyyy", "MMMM d yyyy",
        "MMM d yyyy", "dddd, MMMM d, yyyy", "dddd, d MMMM yyyy", "ddd, d MMM yyyy",
    ].map { FormDates.netTokens($0) }

    /// A value in the field's own format (an AF format string: d day, m month, y year, H and h hours, M minute, s second,
    /// t am/pm), or nil.
    static func parseExact(_ text: String, afFormat: String) -> ScriptDate? {
        guard let tokens = afTokens(afFormat) else { return nil }
        return parse(Array(text.utf16), tokens)
    }

    static func parse(_ text: String) -> ScriptDate? {
        let units = Array(text.utf16)
        for tokens in patterns {
            if let tokens, let date = parse(units, tokens) { return date }
        }
        return nil
    }

    private static func afTokens(_ format: String) -> [Token]? {
        let units = Array(format.utf16)
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            var run = 1
            while i + run < units.count, units[i + run] == c { run += 1 }
            switch c {
            case 0x64: tokens.append(.day(run))
            case 0x48: tokens.append(.hour24(run))
            case 0x68: tokens.append(.hour12(run))
            case 0x73: tokens.append(.second(run))
            case 0x6D: tokens.append(.month(run))
            case 0x4D: tokens.append(.minute(run))
            case 0x79: tokens.append(.year(run >= 4 ? 4 : 2))
            case 0x74: tokens.append(.designator)
            case 0x2F, 0x3A, 0x2D, 0x2C, 0x2E: tokens.append(contentsOf: [Token](repeating: .literal(c), count: run))
            case 0x20: tokens.append(.space)
            case 0x27: return nil
            default: tokens.append(contentsOf: [Token](repeating: .literal(c), count: run))
            }
            i += run
        }
        return tokens
    }

    private static func netTokens(_ pattern: String) -> [Token]? {
        let units = Array(pattern.utf16)
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            var run = 1
            while i + run < units.count, units[i + run] == c { run += 1 }
            switch c {
            case 0x64: tokens.append(.day(run))
            case 0x4D: tokens.append(.month(run))
            case 0x79: tokens.append(.year(run >= 4 ? 4 : 2))
            case 0x48: tokens.append(.hour24(run))
            case 0x68: tokens.append(.hour12(run))
            case 0x6D: tokens.append(.minute(run))
            case 0x73: tokens.append(.second(run))
            case 0x74: tokens.append(.designator)
            case 0x20: tokens.append(.space)
            case 0x27:
                var j = i + 1
                while j < units.count, units[j] != 0x27 {
                    tokens.append(.literal(units[j]))
                    j += 1
                }
                i = j + 1
                continue
            default: tokens.append(contentsOf: [Token](repeating: .literal(c), count: run))
            }
            i += run
        }
        return tokens
    }

    private static func isSpace(_ unit: UInt16) -> Bool { FormScriptParser.isWhiteSpace(unit) }

    private static func parse(_ text: [UInt16], _ tokens: [Token]) -> ScriptDate? {
        var at = 0
        func skipSpace() { while at < text.count, isSpace(text[at]) { at += 1 } }
        func digits(_ length: Int) -> Int? {
            let (low, high) = length == 1 ? (1, 2) : (length, length)
            var value = 0
            var count = 0
            while count < high, at < text.count, FormScriptParser.isDigit(text[at]) {
                value = value * 10 + Int(text[at] - 0x30)
                at += 1
                count += 1
            }
            return count >= low ? value : nil
        }
        func name(_ names: [String], _ length: Int) -> Int? {
            let rest = text[at...]
            var best: (index: Int, length: Int)?
            for (index, full) in names.enumerated() {
                let candidate = Array((length == 3 ? String(full.prefix(3)) : full).utf16)
                guard candidate.count <= rest.count, candidate.count > (best?.length ?? 0),
                      zip(candidate, rest).allSatisfy({ lower($0) == lower($1) }) else { continue }
                best = (index, candidate.count)
            }
            guard let found = best else { return nil }
            at += found.length
            return found.index
        }

        var year: Int?
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
        var second: Int?
        var twoDigitYear = false
        var use12 = false
        var pm: Bool?
        var weekday: Int?

        skipSpace()
        for token in tokens {
            skipSpace()
            switch token {
            case .day(let n):
                if n <= 2 {
                    guard let v = digits(n), day == nil else { return nil }
                    day = v
                } else {
                    guard let v = name(days, n >= 4 ? 4 : 3), weekday == nil else { return nil }
                    weekday = v
                }
            case .month(let n):
                if n <= 2 {
                    guard let v = digits(n), month == nil else { return nil }
                    month = v
                } else {
                    guard let v = name(months, n == 3 ? 3 : 4), month == nil else { return nil }
                    month = v + 1
                }
            case .year(let n):
                guard let v = digits(n), year == nil else { return nil }
                twoDigitYear = n <= 2
                year = v
            case .hour24(let n):
                guard let v = digits(n < 2 ? 1 : 2), hour == nil else { return nil }
                hour = v
            case .hour12(let n):
                guard let v = digits(n < 2 ? 1 : 2), hour == nil else { return nil }
                hour = v
                use12 = true
            case .minute(let n):
                guard let v = digits(n < 2 ? 1 : 2), minute == nil else { return nil }
                minute = v
            case .second(let n):
                guard let v = digits(n < 2 ? 1 : 2), second == nil else { return nil }
                second = v
            case .designator:
                guard pm == nil, at + 2 <= text.count else { return nil }
                let word = String(decoding: text[at..<(at + 2)], as: UTF16.self).uppercased()
                if word == "AM" { pm = false } else if word == "PM" { pm = true } else { return nil }
                at += 2
            case .literal(let c):
                guard at < text.count, text[at] == c else { return nil }
                at += 1
            case .space:
                break
            }
        }
        skipSpace()
        if at != text.count { return nil }

        var h = hour ?? 0
        if use12 {
            guard h <= 12 else { return nil }
            // A 12-hour hour with no designator is read as morning.
            let pm = pm ?? false
            h = pm ? (h == 12 ? 12 : h + 12) : (h == 12 ? 0 : h)
        } else if let pm {
            if pm && h < 12 { h += 12 } else if !pm && h == 12 { h = 0 }
        }
        var date = ScriptDate()
        if let y = year, twoDigitYear {
            year = y <= 49 ? 2000 + y : 1900 + y
        }
        if year == nil || month == nil || day == nil {
            let today = now()
            if month == nil && day == nil && year == nil {
                date.year = today.year
                date.month = today.month
                date.day = today.day
            } else {
                date.year = year ?? today.year
                date.month = month ?? 1
                date.day = day ?? 1
            }
        } else {
            date.year = year ?? 1
            date.month = month ?? 1
            date.day = day ?? 1
        }
        date.hour = h
        date.minute = minute ?? 0
        date.second = second ?? 0
        guard date.year >= 1, date.year <= 9999, date.month >= 1, date.month <= 12, date.day >= 1,
              date.day <= daysIn(date.year, date.month), date.hour <= 23, date.minute <= 59, date.second <= 59 else { return nil }
        if let weekday, weekday != date.dayOfWeek { return nil }
        return date
    }

    private static func lower(_ unit: UInt16) -> UInt16 {
        unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit
    }

    private static func daysIn(_ year: Int, _ month: Int) -> Int {
        if month == 2 { return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    private static func now() -> (year: Int, month: Int, day: Int) {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        return (parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
}
