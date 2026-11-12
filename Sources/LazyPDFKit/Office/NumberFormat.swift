import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/NumberFormat.cs. Codes are read as UTF-16 units, as the C# reads chars.

/// A cell value as text, and the colour the format asked for (0xRRGGBB), if any.
struct FormatResult: Equatable {
    let text: String
    let color: Int?
}

/// An Excel number format code, parsed once and applied to values with the invariant (en-US) separators and names. Digits
/// come from the shortest decimal form of the double cut to 15 significant digits, as Excel does, and are rounded as decimal
/// text, so the C# and Swift engines print the same characters. Locale tags are read and dropped; only a currency symbol in
/// [$...] is kept.
final class NumberFormat {
    private enum Kind { case literal, digit, point, group, percent, exp, slash, at, general, field, elapsed, ampm, subSecond }

    private struct Token {
        var kind: Kind
        var text = ""
        var ch: UInt16 = 0x20
        var count = 0
    }

    private struct Condition {
        let op: String
        let value: Double

        func test(_ v: Double) -> Bool {
            switch op {
            case "<": return v < value
            case "<=": return v <= value
            case ">": return v > value
            case ">=": return v >= value
            case "=": return v == value
            default: return v != value
            }
        }
    }

    private final class Section {
        var tokens: [Token] = []
        var color: Int?
        var cond: Condition?
        var isDate = false
        var hasAt = false
    }

    private static let hashes = "########"
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static let colors: [String: Int] = [
        "black": 0x000000, "blue": 0x0000FF, "cyan": 0x00FFFF, "green": 0x00FF00,
        "magenta": 0xFF00FF, "red": 0xFF0000, "white": 0xFFFFFF, "yellow": 0xFFFF00,
    ]

    private static let indexedColors = [0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF]

    private static let builtIn: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        5: "\"$\"#,##0_);(\"$\"#,##0)", 6: "\"$\"#,##0_);[Red](\"$\"#,##0)",
        7: "\"$\"#,##0.00_);(\"$\"#,##0.00)", 8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "m/d/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
        18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "m/d/yyyy h:mm",
        37: "#,##0_);(#,##0)", 38: "#,##0_);[Red](#,##0)", 39: "#,##0.00_);(#,##0.00)", 40: "#,##0.00_);[Red](#,##0.00)",
        41: "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)",
        42: "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)",
        43: "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)",
        44: "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 48: "##0.0E+0", 49: "@",
    ]

    static let general = parse("General")

    private var sections: [Section] = []

    private init() {}

    /// The code of a built-in format id (0 to 49); nil for the ids that depend on the locale and for ids past 49.
    static func builtInCode(_ id: Int) -> String? { builtIn[id] }

    static func parse(_ code: String) -> NumberFormat {
        let format = NumberFormat()
        for part in split(Array(code.utf16)) { format.sections.append(parseSection(part)) }
        return format
    }

    // Units

    private static func u(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }

    private static func fold(_ c: UInt16) -> UInt16 { c >= 0x41 && c <= 0x5A ? c + 32 : c }

    private static func str<S: Sequence>(_ units: S) -> String where S.Element == UInt16 { String(decoding: Array(units), as: UTF16.self) }

    private static func lower(_ units: [UInt16]) -> String { str(units.map(fold)) }

    private static func slice(_ s: [UInt16], _ from: Int, _ to: Int) -> [UInt16] {
        let end = min(max(to, from), s.count)
        return from >= end ? [] : Array(s[from..<end])
    }

    private static func index(of unit: UInt16, in s: [UInt16], from: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == unit { return i }
            i += 1
        }
        return nil
    }

    private static func split(_ code: [UInt16]) -> [[UInt16]] {
        var parts: [[UInt16]] = []
        var current: [UInt16] = []
        var quoted = false, bracket = false
        var i = 0
        while i < code.count {
            let c = code[i]
            if quoted {
                quoted = c != u("\"")
            } else if bracket {
                bracket = c != u("]")
            } else if c == u("\"") {
                quoted = true
            } else if c == u("[") {
                bracket = true
            } else if (c == u("\\") || c == u("_") || c == u("*")) && i + 1 < code.count {
                current.append(c)
                current.append(code[i + 1])
                i += 2
                continue
            } else if c == u(";") {
                parts.append(current)
                current = []
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        if parts.count > 4 { parts.removeSubrange(4...) }
        return parts
    }

    private static func isElapsed(_ content: [UInt16]) -> Bool {
        ["h", "hh", "m", "mm", "s", "ss"].contains(lower(content))
    }

    private static func isDateSection(_ s: [UInt16]) -> Bool {
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == u("\"") {
                i = index(of: u("\""), in: s, from: i + 1) ?? s.count
            } else if c == u("[") {
                guard let end = index(of: u("]"), in: s, from: i + 1) else { return false }
                if isElapsed(slice(s, i + 1, end)) { return true }
                i = end
            } else if c == u("\\") || c == u("_") || c == u("*") {
                i += 1
            } else if lower(slice(s, i, i + 7)) == "general" {
                i += 6
            } else if "ydhsm".utf16.contains(fold(c)) {
                return true
            }
            i += 1
        }
        return false
    }

    private static func parseSection(_ s: [UInt16]) -> Section {
        let section = Section()
        section.isDate = isDateSection(s)
        var pointSeen = false
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == u("\"") {
                let end = index(of: u("\""), in: s, from: i + 1) ?? s.count
                section.tokens.append(Token(kind: .literal, text: str(slice(s, i + 1, end))))
                i = end + 1
            } else if c == u("\\") {
                if i + 1 < s.count { section.tokens.append(Token(kind: .literal, text: str([s[i + 1]]))) }
                i += 2
            } else if c == u("_") {
                section.tokens.append(Token(kind: .literal, text: " "))
                i += 2
            } else if c == u("*") {
                i += 2
            } else if c == u("[") {
                guard let end = index(of: u("]"), in: s, from: i + 1) else {
                    section.tokens.append(Token(kind: .literal, text: "["))
                    i += 1
                    continue
                }
                bracket(section, slice(s, i + 1, end))
                i = end + 1
            } else if section.isDate {
                i = dateToken(section, s, i)
            } else {
                i = numberToken(section, s, i, &pointSeen)
            }
        }
        return section
    }

    private static func bracket(_ section: Section, _ content: [UInt16]) {
        guard let first = content.first else { return }
        if first == u("<") || first == u(">") || first == u("=") {
            let n = content.count > 1 && (content[1] == u("=") || (first == u("<") && content[1] == u(">"))) ? 2 : 1
            if let value = number(slice(content, n, content.count)) { section.cond = Condition(op: str(content[0..<n]), value: value) }
            return
        }
        let l = lower(content)
        if let rgb = colors[l] {
            section.color = rgb
        } else if l.hasPrefix("color"), let n = Int(String(l.dropFirst(5))), l.utf8.dropFirst(5).allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), n >= 1, n <= 8 {
            section.color = indexedColors[n - 1]
        } else if first == u("$") {
            let dash = index(of: u("-"), in: content, from: 0)
            let symbol = slice(content, 1, dash ?? content.count)
            if !symbol.isEmpty { section.tokens.append(Token(kind: .literal, text: str(symbol))) }
        } else if isElapsed(content) {
            section.tokens.append(Token(kind: .elapsed, ch: l.utf16.first!, count: l.utf16.count))
        }
    }

    private static func run(_ s: [UInt16], _ i: Int) -> Int {
        var j = i
        while j < s.count && fold(s[j]) == fold(s[i]) { j += 1 }
        return j - i
    }

    private static func dateToken(_ section: Section, _ s: [UInt16], _ i: Int) -> Int {
        let c = s[i]
        let l = fold(c)
        if "ymdhs".utf16.contains(l) {
            let n = run(s, i)
            section.tokens.append(Token(kind: .field, ch: l, count: n))
            return i + n
        }
        if l == u("a") {
            if i + 5 <= s.count && lower(slice(s, i, i + 5)) == "am/pm" {
                section.tokens.append(Token(kind: .ampm, text: str(slice(s, i, i + 5))))
                return i + 5
            }
            if i + 3 <= s.count && lower(slice(s, i, i + 3)) == "a/p" {
                section.tokens.append(Token(kind: .ampm, text: str(slice(s, i, i + 3))))
                return i + 3
            }
        }
        if c == u("."), let last = section.tokens.last, last.ch == u("s"), last.kind == .field || last.kind == .elapsed,
           i + 1 < s.count, s[i + 1] == u("0") {
            var n = 1
            while i + 1 + n < s.count && s[i + 1 + n] == u("0") { n += 1 }
            section.tokens.append(Token(kind: .subSecond, count: min(n, 3)))
            return i + 1 + n
        }
        section.tokens.append(Token(kind: .literal, text: str([c])))
        return i + 1
    }

    private static func numberToken(_ section: Section, _ s: [UInt16], _ i: Int, _ pointSeen: inout Bool) -> Int {
        let c = s[i]
        if c == u("0") || c == u("#") || c == u("?") {
            section.tokens.append(Token(kind: .digit, ch: c))
            return i + 1
        }
        if c == u(".") && !pointSeen && !section.tokens.contains(where: { $0.kind == .exp }) {
            pointSeen = true
            section.tokens.append(Token(kind: .point))
            return i + 1
        }
        if c == u(",") {
            section.tokens.append(Token(kind: .group))
            return i + 1
        }
        if c == u("%") {
            section.tokens.append(Token(kind: .percent))
            return i + 1
        }
        if (c == u("E") || c == u("e")) && i + 1 < s.count && (s[i + 1] == u("+") || s[i + 1] == u("-")) {
            section.tokens.append(Token(kind: .exp, ch: s[i + 1]))
            return i + 2
        }
        if c == u("/") {
            section.tokens.append(Token(kind: .slash))
            return i + 1
        }
        if c == u("@") {
            section.hasAt = true
            section.tokens.append(Token(kind: .at))
            return i + 1
        }
        if (c == u("G") || c == u("g")) && i + 7 <= s.count && lower(slice(s, i, i + 7)) == "general" {
            section.tokens.append(Token(kind: .general))
            return i + 7
        }
        section.tokens.append(Token(kind: .literal, text: str([c])))
        return i + 1
    }

    private static func number(_ text: [UInt16]) -> Double? {
        if text.isEmpty { return nil }
        for c in text where !((c >= 0x30 && c <= 0x39) || c == u("+") || c == u("-") || c == u(".") || c == u("e") || c == u("E")) { return nil }
        guard let v = Double(str(text)), v.isFinite else { return nil }
        return v
    }

    // Applying a format

    func format(_ v: Double, date1904: Bool) -> FormatResult {
        let numeric = min(sections.count, 3)
        var at = numeric - 1
        for i in 0..<numeric where matches(i, numeric, v) {
            at = i
            break
        }
        let section = sections[at]
        if section.tokens.isEmpty { return FormatResult(text: "", color: section.color) }
        let negative = v < 0
        let dropMinus = negative && at == 1 && section.cond == nil
        if section.isDate { return FormatResult(text: Self.date(section, v, date1904), color: section.color) }
        let text = Self.digits(section, abs(v))
        return FormatResult(text: negative && !dropMinus ? "-" + text : text, color: section.color)
    }

    private func matches(_ i: Int, _ numeric: Int, _ v: Double) -> Bool {
        let s = sections[i]
        if let c = s.cond { return c.test(v) }
        if numeric == 1 { return true }
        if i == 0 { return numeric == 2 && sections[1].cond == nil ? v >= 0 : v > 0 }
        if i == 1 { return numeric == 2 || v < 0 }
        return true
    }

    /// A text value through the text section, if the format has one; else the text as it is.
    func formatText(_ text: String) -> FormatResult {
        guard let section = sections.last(where: { $0.hasAt }) ?? (sections.count == 4 ? sections[3] : nil) else {
            return FormatResult(text: text, color: nil)
        }
        var o = ""
        for t in section.tokens {
            if t.kind == .at { o += text } else if t.kind == .literal { o += t.text }
        }
        return FormatResult(text: o, color: section.color)
    }

    // Decimal digits

    private struct Dec {
        /// ASCII digits, no leading or trailing zeros; empty is zero.
        var digits: [UInt8] = []
        /// The value is 0.digits times ten to the point.
        var point = 0

        static func from(_ v: Double) -> Dec {
            var s = Array("\(abs(v))".utf8)
            var exp = 0
            if let e = s.firstIndex(where: { $0 == 0x45 || $0 == 0x65 }) {
                exp = Int(String(decoding: s[(e + 1)...], as: UTF8.self)) ?? 0
                s = Array(s[..<e])
            }
            let dot = s.firstIndex(of: 0x2E)
            var digits = dot.map { Array(s[..<$0]) + Array(s[($0 + 1)...]) } ?? s
            let point = (dot ?? s.count) + exp
            var lead = 0
            while lead < digits.count && digits[lead] == 0x30 { lead += 1 }
            digits.removeFirst(lead)
            while digits.last == 0x30 { digits.removeLast() }
            var d = Dec(digits: digits, point: digits.isEmpty ? 0 : point - lead)
            d.roundAt(15)
            return d
        }

        mutating func roundAt(_ cut: Int) {
            if cut >= digits.count { return }
            if cut < 0 {
                digits = []
                point = 0
                return
            }
            var kept = Array(digits[..<cut])
            if digits[cut] >= 0x35 {
                var i = cut - 1
                while i >= 0 && kept[i] == 0x39 {
                    kept[i] = 0x30
                    i -= 1
                }
                if i >= 0 {
                    kept[i] += 1
                } else {
                    digits = [0x31] + kept
                    while digits.last == 0x30 { digits.removeLast() }
                    point += 1
                    return
                }
            }
            while kept.last == 0x30 { kept.removeLast() }
            digits = kept
            if digits.isEmpty { point = 0 }
        }

        var intDigits: String {
            if point <= 0 { return "" }
            let shown = digits.count >= point ? Array(digits[..<point]) : digits + [UInt8](repeating: 0x30, count: point - digits.count)
            return String(decoding: shown, as: UTF8.self)
        }

        func fraction(_ count: Int) -> [UInt8] {
            (0..<count).map { j in
                let at = point + j
                return at >= 0 && at < digits.count ? digits[at] : 0x30
            }
        }
    }

    /// Excel's General for a number: up to 11 significant digits, then E notation.
    static func generalText(_ v: Double) -> String {
        if v == 0 { return "0" }
        let sign = v < 0 ? "-" : ""
        var d = Dec.from(v)
        d.roundAt(11)
        var e = d.point - 1
        if e >= 11 || e < -4 {
            d = Dec.from(v)
            d.roundAt(6)
            e = d.point - 1
            let all = String(decoding: d.digits, as: UTF8.self)
            let mantissa = d.digits.count > 1 ? String(all.prefix(1)) + "." + String(all.dropFirst()) : all
            let digits = "\(abs(e))"
            return sign + mantissa + "E" + (e < 0 ? "-" : "+") + (digits.count < 2 ? "0" + digits : digits)
        }
        let all = String(decoding: d.digits, as: UTF8.self)
        let plain: String
        if d.point <= 0 {
            plain = "0." + String(repeating: "0", count: -d.point) + all
        } else if d.digits.count <= d.point {
            plain = all + String(repeating: "0", count: d.point - d.digits.count)
        } else {
            plain = String(all.prefix(d.point)) + "." + String(all.dropFirst(d.point))
        }
        return sign + plain
    }

    /// The pieces the integer digits make in a row of placeholders: from the right, a digit each; past the digits a 0 shows 0, a ?
    /// a space, a # nothing; digits beyond the placeholders go into the first one. A comma comes before every third digit.
    private static func place(_ placeholders: [UInt16], _ digits: String, _ grouping: Bool) -> [String] {
        let count = placeholders.count
        let d = Array(digits.utf8)
        let n = d.count
        let slots = max(n, count)
        func slot(_ k: Int) -> String? {
            if k < n { return String(decoding: [d[n - 1 - k]], as: UTF8.self) }
            if k < count {
                let p = placeholders[count - 1 - k]
                return p == u("0") ? "0" : p == u("?") ? " " : nil
            }
            return nil
        }
        func piece(_ k: Int) -> String {
            let comma = grouping && (k + 1) % 3 == 0 && k + 1 < slots && (slot(k + 1).map { $0 != " " } ?? false) ? "," : ""
            return comma + (slot(k) ?? "")
        }
        var pieces = [String](repeating: "", count: count)
        if count > 1 {
            for p in 1..<count { pieces[p] = piece(count - 1 - p) }
        }
        if count > 0 {
            var first = ""
            var k = slots - 1
            while k >= count - 1 {
                first += piece(k)
                k -= 1
            }
            pieces[0] = first
        }
        return pieces
    }

    private static func isDigitLiteral(_ t: Token) -> Bool {
        t.kind == .literal && !t.text.isEmpty && t.text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    // Excel's tenths and hundredths codes ("# ?/10") put a 0 in the fixed denominator, which tokenizes as a digit.
    private static func isFixedDenominator(_ t: Token) -> Bool {
        isDigitLiteral(t) || (t.kind == .digit && t.ch == u("0"))
    }

    private static func denominatorText(_ t: Token) -> String {
        t.kind == .digit ? String(utf16CodeUnits: [t.ch], count: 1) : t.text
    }

    private static func digits(_ section: Section, _ v: Double) -> String {
        let tokens = section.tokens
        if let slash = tokens.firstIndex(where: { $0.kind == .slash }), slash > 0, tokens[slash - 1].kind == .digit,
           slash + 1 < tokens.count, tokens[slash + 1].kind == .digit || isDigitLiteral(tokens[slash + 1]) {
            return fraction(section, v, slash)
        }
        let point = tokens.firstIndex { $0.kind == .point } ?? -1
        let exp = tokens.firstIndex { $0.kind == .exp } ?? -1
        let intEnd = point >= 0 ? point : exp >= 0 ? exp : tokens.count
        let numberEnd = exp >= 0 ? exp : tokens.count

        var grouping = false
        var scale = 0
        var consumed = [Bool](repeating: false, count: tokens.count)
        for i in 0..<tokens.count where tokens[i].kind == .group {
            let before = tokens[..<i].contains { $0.kind == .digit }
            let limit = i < intEnd ? intEnd : numberEnd
            let afterCount = max(0, limit - i - 1)
            let after = tokens.dropFirst(i + 1).prefix(afterCount).contains { $0.kind == .digit }
            if before && after && i < intEnd {
                grouping = true
                consumed[i] = true
            } else if before && !after {
                scale += 1
                consumed[i] = true
            }
        }
        let percents = tokens.filter { $0.kind == .percent }.count

        var number = Dec.from(v)
        number.point += 2 * percents - 3 * scale

        var intHolders: [UInt16] = []
        var fracHolders: [UInt16] = []
        var expDigits = 0
        for i in 0..<tokens.count where tokens[i].kind == .digit {
            if exp >= 0 && i > exp {
                expDigits += 1
            } else if point >= 0 && i > point {
                fracHolders.append(tokens[i].ch)
            } else {
                intHolders.append(tokens[i].ch)
            }
        }

        var exponent = 0
        if exp >= 0 {
            let width = max(1, intHolders.count)
            if !number.digits.isEmpty {
                let e = number.point - 1
                exponent = (e >= 0 ? e / width : -((-e + width - 1) / width)) * width
            }
            number.point -= exponent
            number.roundAt(number.point + fracHolders.count)
            if !number.digits.isEmpty && number.point > width {
                exponent += width
                number.point -= width
            }
        } else {
            number.roundAt(number.point + fracHolders.count)
        }

        let intPieces = place(intHolders, number.intDigits, grouping)
        let fractionDigits = number.fraction(fracHolders.count)
        var lastShown = -1
        for j in 0..<fracHolders.count where fractionDigits[j] != 0x30 || fracHolders[j] == u("0") { lastShown = j }

        var o = ""
        var ip = 0, fp = 0, xp = 0
        for i in 0..<tokens.count {
            let t = tokens[i]
            switch t.kind {
            case .digit where exp >= 0 && i > exp:
                if xp == 0 {
                    let digits = "\(abs(exponent))"
                    o += String(repeating: "0", count: max(0, expDigits - digits.count)) + digits
                }
                xp += 1
            case .digit where point >= 0 && i > point:
                o += fp > lastShown ? (fracHolders[fp] == u("?") ? " " : "") : String(decoding: [fractionDigits[fp]], as: UTF8.self)
                fp += 1
            case .digit:
                o += intPieces[ip]
                ip += 1
            case .point:
                if intHolders.isEmpty && !number.intDigits.isEmpty { o += number.intDigits }
                o += "."
            case .group:
                if !consumed[i] { o += "," }
            case .percent:
                o += "%"
            case .exp:
                o += "E" + (exponent < 0 ? "-" : t.ch == u("+") ? "+" : "")
            case .general, .at:
                o += generalText(v)
            case .literal:
                o += t.text
            default:
                break
            }
        }
        return o
    }

    private static func fraction(_ section: Section, _ v: Double, _ slash: Int) -> String {
        let tokens = section.tokens
        var numStart = slash
        while numStart > 0 && tokens[numStart - 1].kind == .digit { numStart -= 1 }
        var denEnd = slash + 1
        let fixedDenominator = isDigitLiteral(tokens[slash + 1])
        if fixedDenominator {
            while denEnd < tokens.count && isFixedDenominator(tokens[denEnd]) { denEnd += 1 }
        } else {
            while denEnd < tokens.count && tokens[denEnd].kind == .digit { denEnd += 1 }
        }

        var wholeHolders: [UInt16] = []
        for i in 0..<numStart where tokens[i].kind == .digit { wholeHolders.append(tokens[i].ch) }
        let numHolders = tokens[numStart..<slash].map { $0.ch }
        let denCount = denEnd - slash - 1

        let hasWhole = !wholeHolders.isEmpty
        var whole = hasWhole ? v.rounded(.down) : 0
        let rest = v - whole
        var n: Double, d: Double
        if fixedDenominator {
            d = Double(tokens[(slash + 1)..<(slash + 1 + denCount)].map(denominatorText).joined()) ?? 1
            if d < 1 { d = 1 }
            n = (rest * d + 0.5).rounded(.down)
        } else {
            var maxDenominator = 1.0
            for _ in 0..<min(denCount, 4) { maxDenominator *= 10 }
            maxDenominator -= 1
            d = 1
            n = (rest + 0.5).rounded(.down)
            var best = abs(rest - n)
            var c = 2.0
            while c <= maxDenominator && best > 0 {
                let cn = (rest * c + 0.5).rounded(.down)
                let error = abs(rest - cn / c)
                if error < best {
                    best = error
                    d = c
                    n = cn
                }
                c += 1
            }
        }
        if hasWhole && n >= d {
            let carry = (n / d).rounded(.down)
            whole += carry
            n -= carry * d
        }
        let blank = hasWhole && n == 0

        let wholePieces = place(wholeHolders, Dec.from(whole).intDigits, false)
        let numPieces = place(numHolders, n == 0 ? "0" : Dec.from(n).intDigits, false)
        let denominator = Array(Dec.from(d).intDigits)

        var o = ""
        var wp = 0, np = 0, dp = 0
        for i in 0..<tokens.count {
            let t = tokens[i]
            if i >= numStart && i < slash {
                o += blank ? " " : numPieces[np]
                np += 1
            } else if i == slash {
                o += blank ? " " : "/"
            } else if i > slash && i < denEnd {
                if blank {
                    o += String(repeating: " ", count: t.kind == .digit ? 1 : t.text.utf16.count)
                } else if fixedDenominator {
                    o += denominatorText(t)
                } else {
                    o += dp < denominator.count ? String(denominator[dp]) : t.ch == u("?") ? " " : ""
                    dp += 1
                }
            } else if t.kind == .digit {
                o += wholePieces[wp]
                wp += 1
            } else if t.kind == .literal {
                o += t.text
            } else if t.kind == .percent {
                o += "%"
            }
        }
        return o
    }

    // Dates and times

    private static func civil(_ unixDays: Int) -> (year: Int, month: Int, day: Int) {
        let z = unixDays + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = "\(n)"
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private static func date(_ section: Section, _ v: Double, _ date1904: Bool) -> String {
        if v < 0 || v >= 1e8 { return hashes }
        let tokens = section.tokens
        let sub = tokens.first { $0.kind == .subSecond }?.count ?? 0
        let scale = sub == 0 ? 1 : sub == 1 ? 10 : sub == 2 ? 100 : 1000
        let perDay = 86400 * scale
        let total = Int((v * Double(perDay) + 0.5).rounded(.down))
        let days = total / perDay
        let rem = total % perDay
        let seconds = rem / scale
        let hour = seconds / 3600, minute = seconds % 3600 / 60, second = seconds % 60

        var year = 0, month = 0, day = 0, weekday = 0
        if date1904 {
            (year, month, day) = civil(days - 24107)
            weekday = (days + 5) % 7
        } else {
            if days == 0 {
                (year, month, day) = (1900, 1, 0)
            } else if days == 60 {
                (year, month, day) = (1900, 2, 29)
            } else {
                (year, month, day) = civil(days < 60 ? days - 25568 : days - 25569)
            }
            weekday = ((days - 1) % 7 + 7) % 7
        }
        if year > 9999 { return hashes }

        let twelve = tokens.contains { $0.kind == .ampm }
        var o = ""
        for i in 0..<tokens.count {
            let t = tokens[i]
            switch t.kind {
            case .literal:
                o += t.text
            case .ampm:
                let pm = hour >= 12
                let word = t.text.utf16.count == 5 ? (pm ? "PM" : "AM") : (pm ? "P" : "A")
                let first = t.text.utf16.first ?? 0x41
                o += first >= 0x61 && first <= 0x7A ? word.lowercased() : word
            case .subSecond:
                o += "." + pad(rem % scale, sub)
            case .elapsed:
                let value = t.ch == u("h") ? days * 24 + hour : t.ch == u("m") ? days * 1440 + hour * 60 + minute : days * 86400 + seconds
                o += pad(value, t.count)
            case .field:
                field(&o, t, i, tokens, year, month, day, weekday, hour, minute, second, twelve)
            default:
                break
            }
        }
        return o
    }

    private static func isMinute(_ tokens: [Token], _ at: Int) -> Bool {
        var i = at - 1
        while i >= 0 {
            if tokens[i].kind == .field || tokens[i].kind == .elapsed { return tokens[i].ch == u("h") }
            i -= 1
        }
        i = at + 1
        while i < tokens.count {
            if tokens[i].kind == .field || tokens[i].kind == .elapsed { return tokens[i].ch == u("s") }
            i += 1
        }
        return false
    }

    private static func field(_ o: inout String, _ t: Token, _ at: Int, _ tokens: [Token], _ year: Int, _ month: Int, _ day: Int,
                              _ weekday: Int, _ hour: Int, _ minute: Int, _ second: Int, _ twelve: Bool) {
        switch t.ch {
        case u("y"):
            o += t.count <= 2 ? pad(year % 100, 2) : pad(year, 4)
        case u("m") where isMinute(tokens, at):
            o += t.count == 1 ? "\(minute)" : pad(minute, 2)
        case u("m"):
            let name = month >= 1 ? months[month - 1] : "January"
            switch t.count {
            case 1: o += "\(month)"
            case 2: o += pad(month, 2)
            case 3: o += String(name.prefix(3))
            case 4: o += name
            default: o += String(name.prefix(1))
            }
        case u("d"):
            switch t.count {
            case 1: o += "\(day)"
            case 2: o += pad(day, 2)
            case 3: o += String(days[weekday].prefix(3))
            default: o += days[weekday]
            }
        case u("h"):
            let h = twelve ? (hour % 12 == 0 ? 12 : hour % 12) : hour
            o += t.count == 1 ? "\(h)" : pad(h, 2)
        case u("s"):
            o += t.count == 1 ? "\(second)" : pad(second, 2)
        default:
            break
        }
    }
}
