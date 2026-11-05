import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormFunctions.cs: the AF functions Acrobat writes into form actions (the AForm.js of
// its JavaScript library), run here: number, percent, date, time and special formats, the matching keystroke checks,
// ranges and the simple calculations. Month and day names are English.

struct Formatted {
    let text: String
    let color: [Double]?
}

enum FormFunctions {
    private static let dateFormats = [
        "m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy",
        "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM",
    ]

    private static let timeFormats = ["HH:MM", "h:MM tt", "HH:MM:ss", "h:MM:ss tt"]

    static func isFormat(_ call: FormCall) -> Bool { call.name.hasSuffix("_Format") || call.name.hasSuffix("_FormatEx") }

    /// The value as the format function shows it; nil when the call is not a format or the value does not fit it (the raw
    /// value is shown then).
    static func format(_ call: FormCall, _ value: String) -> Formatted? {
        if value.isEmpty { return nil }
        switch call.name {
        case "AFNumber_Format":
            guard let n = parseNumber(value, Int(saturating32: call.number(1))) else { return nil }
            return number(n, Int(saturating32: call.number(0)), Int(saturating32: call.number(1)), Int(saturating32: call.number(2)),
                          call.text(4), call.flag(5, true), percent: false)
        case "AFPercent_Format":
            guard let p = parseNumber(value), (p * 100).isFinite else { return nil }
            return number(p * 100, Int(saturating32: call.number(0)), Int(saturating32: call.number(1)), 0, "", true, percent: true)
        case "AFDate_Format", "AFDate_FormatEx", "AFTime_Format", "AFTime_FormatEx":
            let pattern = dateFormat(call)
            guard let d = parseDate(value, pattern) else { return nil }
            return Formatted(text: printDate(d, pattern), color: nil)
        case "AFSpecial_Format":
            guard let s = special(Int(saturating32: call.number(0)), value) else { return nil }
            return Formatted(text: s, color: nil)
        default:
            return nil
        }
    }

    /// The keystroke or range check of a call: nil when the value passes, else what to tell the user.
    static func check(_ call: FormCall, _ value: String) -> String? {
        if value.isEmpty { return nil }
        switch call.name {
        case "AFNumber_Keystroke", "AFPercent_Keystroke":
            return parseNumber(value) == nil ? FormText.badNumber : nil
        case "AFDate_Keystroke", "AFDate_KeystrokeEx", "AFTime_Keystroke", "AFTime_KeystrokeEx":
            return FormDates.parse(value) == nil ? FormText.badDate : nil
        case "AFSpecial_Keystroke":
            return special(Int(saturating32: call.number(0)), value) == nil ? FormText.badFormat : nil
        case "AFSpecial_KeystrokeEx":
            return matchesMask(call.text(0), value) ? nil : FormText.badFormat
        case "AFRange_Validate":
            return range(call, value)
        default:
            return nil
        }
    }

    /// AFSimple_Calculate over the values of the fields; text that is not a number is skipped.
    static func calculate(_ call: FormCall, _ valuesOf: (String) -> [String?]) -> String? {
        if call.name != "AFSimple_Calculate" { return nil }
        let function = call.text(0)
        var names: [String] = []
        if call.args.count >= 2 {
            switch call.args[1] {
            case .list(let list):
                for case .text(let s) in list { names.append(s) }
            case .text(let one):
                names = one.split(separator: ",", omittingEmptySubsequences: false).map { trim(String($0)) }
            default:
                break
            }
        }
        var numbers: [Double] = []
        for name in names {
            for v in valuesOf(name) {
                if let v, let n = parseNumber(v) { numbers.append(n) }
            }
        }
        let result: Double
        switch function {
        case "SUM": result = numbers.reduce(0, +)
        case "AVG": result = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
        case "PRD": result = numbers.isEmpty ? 0 : numbers.reduce(1.0, *)
        case "MIN": result = numbers.min() ?? 0
        case "MAX": result = numbers.max() ?? 0
        default: result = Double.nan
        }
        return result.isFinite ? numberText(result) : nil
    }

    /// Math.Round(value, 10).ToString("R", InvariantCulture). Math.Round goes through value * 1e10, which moves a large whole
    /// number by a few units in the last place; from 2^43 on a double has no digits beyond the tenth to round off.
    static func numberText(_ value: Double) -> String {
        let rounded = abs(value) < 1e13 ? (value * 1e10).rounded(.toNearestOrEven) / 1e10 : value
        return roundTrip(rounded)
    }

    // The shortest digits that read back as the same double, laid out as .NET writes them: scientific from 1E+17 and below
    // 1E-05, at least two exponent digits.
    private static func roundTrip(_ value: Double) -> String {
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        let text = "\(abs(value))"
        let halves = text.split(separator: "e", maxSplits: 1)
        let mantissa = halves[0]
        var exponent = halves.count > 1 ? Int(halves[1]) ?? 0 : 0
        let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = mantissa.filter { $0 != "." }.map { Int(String($0)) ?? 0 }
        var position = point + exponent
        while digits.first == 0 {
            digits.removeFirst()
            position -= 1
        }
        while digits.last == 0 { digits.removeLast() }
        exponent = position - 1
        let all = digits.map { String($0) }.joined()
        if all.isEmpty { return sign + "0" }
        if exponent >= 17 || exponent <= -5 {
            let rest = all.dropFirst()
            let magnitude = abs(exponent)
            return sign + String(all.prefix(1)) + (rest.isEmpty ? "" : "." + rest) + "E" + (exponent < 0 ? "-" : "+") + (magnitude < 10 ? "0" : "") + String(magnitude)
        }
        if exponent >= 0 {
            let whole = all.count > exponent + 1 ? String(all.prefix(exponent + 1)) : all + String(repeating: "0", count: exponent + 1 - all.count)
            let fraction = all.count > exponent + 1 ? String(all.dropFirst(exponent + 1)) : ""
            return sign + whole + (fraction.isEmpty ? "" : "." + fraction)
        }
        return sign + "0." + String(repeating: "0", count: -exponent - 1) + all
    }

    // Under a style with a comma as the decimal mark a lone dot followed by three digits is a group mark.
    private static func parseNumber(_ text: String, _ separatorStyle: Int) -> Double? {
        var t = trim(text)
        if separatorStyle == 2 && !t.contains(",") && t.contains(".") {
            let parts = t.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
            if parts.allSatisfy({ $0.utf16.count == 3 && $0.utf16.allSatisfy { FormScriptParser.isDigit($0) } }) {
                t = t.replacingOccurrences(of: ".", with: "")
            }
        }
        return parseNumber(t)
    }

    /// A number from the text a person or an export wrote: either decimal mark, any grouping, a currency sign, a minus or
    /// parentheses.
    static func parseNumber(_ text: String) -> Double? {
        let units = Array(trim(text).utf16)
        func numeric(_ c: UInt16) -> Bool { FormScriptParser.isDigit(c) || c == 0x2E || c == 0x2C }
        guard let first = units.firstIndex(where: numeric), let last = units.lastIndex(where: numeric) else { return nil }
        if (first > 0 && isLetter(units[first - 1])) || (last + 1 < units.count && isLetter(units[last + 1])) { return nil }
        let inner = Array(units[first...last])
        if inner.contains(where: { !(numeric($0) || $0 == 0x27 || $0 == 0x20) }) { return nil }
        let negative = units.contains(0x2D) || (units.first == 0x28 && units.last == 0x29)
        var s = String(decoding: inner.filter { $0 != 0x27 && $0 != 0x20 }, as: UTF16.self)
        let dot = s.lastIndex(of: "."), comma = s.lastIndex(of: ",")
        if let dot, let comma {
            s = dot > comma ? s.replacingOccurrences(of: ",", with: "") : s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if let comma {
            let commas = s.filter { $0 == "," }.count
            let after = s.distance(from: comma, to: s.endIndex) - 1
            s = commas == 1 && after != 3 ? s.replacingOccurrences(of: ",", with: ".") : s.replacingOccurrences(of: ",", with: "")
        } else if dot != nil, s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard let value = InvariantNumbers.parseDouble(s) else { return nil }
        return negative ? -abs(value) : value
    }

    private static let powers: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15]

    // Math.Round(value, digits, MidpointRounding.AwayFromZero).
    private static func roundAway(_ value: Double, _ digits: Int) -> Double {
        if abs(value) >= 1e16 { return value }
        let power = powers[digits]
        return (value * power).rounded(.toNearestOrAwayFromZero) / power
    }

    private static func number(_ value: Double, _ decimalPlaces: Int, _ separators: Int, _ negative: Int, _ currency: String, _ prepend: Bool, percent: Bool) -> Formatted {
        let decimals = min(max(decimalPlaces, 0), 15)
        let rounded = roundAway(abs(value), decimals)
        let isNegative = value < 0 && rounded != 0
        let text = String(format: "%.\(decimals)f", rounded)
        var whole = text
        var fraction = ""
        if decimals > 0, let dot = text.firstIndex(of: ".") {
            whole = String(text[..<dot])
            fraction = String(text[text.index(after: dot)...])
        }
        let group: String, mark: String
        switch separators {
        case 0: (group, mark) = (",", ".")
        case 1: (group, mark) = ("", ".")
        case 2: (group, mark) = (".", ",")
        case 3: (group, mark) = ("", ",")
        default: (group, mark) = ("'", ".")
        }
        if !group.isEmpty {
            var grouped = ""
            let digits = Array(whole)
            for i in 0..<digits.count {
                if i > 0 && (digits.count - i) % 3 == 0 { grouped += group }
                grouped.append(digits[i])
            }
            whole = grouped
        }
        var body = decimals > 0 ? whole + mark + fraction : whole
        if percent {
            body += "%"
        } else if !currency.isEmpty {
            body = prepend ? currency + body : body + currency
        }
        if isNegative { body = negative >= 2 ? "(" + body + ")" : "-" + body }
        return Formatted(text: body, color: isNegative && (negative == 1 || negative == 3) ? [1, 0, 0] : nil)
    }

    private static func range(_ call: FormCall, _ value: String) -> String? {
        guard let n = parseNumber(value) else { return FormText.badNumber }
        let hasMin = call.flag(0), hasMax = call.flag(2)
        let min = call.number(1), max = call.number(3)
        if (hasMin && n < min) || (hasMax && n > max) {
            let low = numberText(min), high = numberText(max)
            if hasMin && hasMax { return FormText.outOfRange(low, high) }
            return hasMin ? FormText.atLeast(low) : FormText.atMost(high)
        }
        return nil
    }

    private static func dateFormat(_ call: FormCall) -> String {
        switch call.name {
        case "AFDate_Format": return dateFormats[min(max(Int(saturating32: call.number(0)), 0), dateFormats.count - 1)]
        case "AFTime_Format": return timeFormats[min(max(Int(saturating32: call.number(0)), 0), timeFormats.count - 1)]
        default: return call.text(0)
        }
    }

    // A value in the field's own format is read by it first: 03/04/2024 under dd/mm/yyyy is the third of April.
    private static func parseDate(_ text: String, _ format: String) -> ScriptDate? {
        FormDates.parseExact(trim(text), afFormat: format) ?? FormDates.parse(text)
    }

    // The letters of util.printd: d day, m month, y year, H 24-hour, h 12-hour, M minute, s second, t am/pm.
    private static func printDate(_ d: ScriptDate, _ format: String) -> String {
        var result = ""
        let units = Array(format.utf16)
        func two(_ v: Int) -> String { v < 10 ? "0" + String(v) : String(v) }
        var i = 0
        while i < units.count {
            let c = units[i]
            var run = 1
            while i + run < units.count, units[i + run] == c { run += 1 }
            let hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12
            switch c {
            case 0x64:
                let name = FormDates.days[d.dayOfWeek]
                result += run >= 4 ? name : run == 3 ? String(name.prefix(3)) : run == 2 ? two(d.day) : String(d.day)
            case 0x6D:
                let name = FormDates.months[d.month - 1]
                result += run >= 4 ? name : run == 3 ? String(name.prefix(3)) : run == 2 ? two(d.month) : String(d.month)
            case 0x79:
                result += run >= 4 ? String(repeating: "0", count: d.year < 1000 ? (d.year < 100 ? (d.year < 10 ? 3 : 2) : 1) : 0) + String(d.year) : two(d.year % 100)
            case 0x48: result += run >= 2 ? two(d.hour) : String(d.hour)
            case 0x68: result += run >= 2 ? two(hour12) : String(hour12)
            case 0x4D: result += run >= 2 ? two(d.minute) : String(d.minute)
            case 0x73: result += run >= 2 ? two(d.second) : String(d.second)
            case 0x74: result += d.hour < 12 ? "am" : "pm"
            default: result += String(decoding: [UInt16](repeating: c, count: run), as: UTF16.self)
            }
            i += run
        }
        return result
    }

    private static func special(_ kind: Int, _ value: String) -> String? {
        let digits = Array(value.utf16.filter { FormScriptParser.isDigit($0) }.map { Character(Unicode.Scalar($0) ?? "0") })
        func part(_ from: Int, _ to: Int) -> String { String(digits[from..<to]) }
        switch kind {
        case 0 where digits.count == 5: return String(digits)
        case 1 where digits.count == 9: return part(0, 5) + "-" + part(5, 9)
        case 2 where digits.count == 10: return "(" + part(0, 3) + ") " + part(3, 6) + "-" + part(6, 10)
        case 2 where digits.count == 7: return part(0, 3) + "-" + part(3, 7)
        case 3 where digits.count == 9: return part(0, 3) + "-" + part(3, 5) + "-" + part(5, 9)
        default: return nil
        }
    }

    private static func matchesMask(_ mask: String, _ value: String) -> Bool {
        let m = Array(mask.utf16), v = Array(value.utf16)
        if m.count != v.count { return false }
        for i in 0..<m.count {
            let ok: Bool
            switch m[i] {
            case 0x39: ok = FormScriptParser.isDigit(v[i])
            case 0x41: ok = isLetter(v[i])
            case 0x4F: ok = isLetter(v[i]) || isDecimalDigit(v[i])
            case 0x58: ok = true
            default: ok = v[i] == m[i]
            }
            if !ok { return false }
        }
        return true
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isDecimalDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.generalCategory == .decimalNumber
    }

    /// string.Trim().
    static func trim(_ text: String) -> String {
        var units = Array(text.utf16)
        while let last = units.last, FormScriptParser.isWhiteSpace(last) { units.removeLast() }
        var start = 0
        while start < units.count, FormScriptParser.isWhiteSpace(units[start]) { start += 1 }
        return String(decoding: units[start...], as: UTF16.self)
    }
}
