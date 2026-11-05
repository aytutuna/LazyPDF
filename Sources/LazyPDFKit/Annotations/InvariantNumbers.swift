import Foundation

// No C# twin: what double.TryParse and int.TryParse (NumberStyles.Float and HexNumber) and ToString("0.##") do under
// the invariant culture, for the text this layer reads and writes. Swift's Double(_:) takes more (hex floats, "inf",
// "nan") and trims nothing.

enum InvariantNumbers {
    private static func isWhite(_ c: Unicode.Scalar) -> Bool {
        c == " " || (c.value >= 0x09 && c.value <= 0x0D)
    }

    private static func trimmed(_ text: String) -> [Unicode.Scalar] {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, isWhite(last) { scalars.removeLast() }
        var start = 0
        while start < scalars.count, isWhite(scalars[start]) { start += 1 }
        return Array(scalars[start...])
    }

    /// A finite number as `double.TryParse(text, NumberStyles.Float, InvariantCulture)` reads it, or nil.
    static func parseDouble(_ text: String?) -> Double? {
        guard let text else { return nil }
        let s = trimmed(text)
        var i = 0
        if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
        var digits = 0
        while i < s.count, s[i].value >= 0x30, s[i].value <= 0x39 { i += 1; digits += 1 }
        if i < s.count, s[i] == "." {
            i += 1
            while i < s.count, s[i].value >= 0x30, s[i].value <= 0x39 { i += 1; digits += 1 }
        }
        if digits == 0 { return nil }
        if i < s.count, s[i] == "e" || s[i] == "E" {
            i += 1
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            var exponent = 0
            while i < s.count, s[i].value >= 0x30, s[i].value <= 0x39 { i += 1; exponent += 1 }
            if exponent == 0 { return nil }
        }
        if i != s.count { return nil }
        guard let value = Double(String(String.UnicodeScalarView(s))), value.isFinite else { return nil }
        return value
    }

    /// `int.TryParse(text, out value)`: white space, a sign and digits, within the range of an `int`.
    static func parseInt(_ text: String) -> Int? {
        var s = trimmed(text)
        var negative = false
        if let sign = s.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            s.removeFirst()
        }
        return digitsValue(s, negative)
    }

    /// `int.TryParse(text, NumberStyles.AllowLeadingSign, InvariantCulture, out value)`: a sign and digits, nothing else.
    static func parseSignedInt(_ text: String?) -> Int? {
        guard let text else { return nil }
        var s = Array(text.unicodeScalars)
        var negative = false
        if let sign = s.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            s.removeFirst()
        }
        return digitsValue(s, negative)
    }

    // Leading zeros are digits to .NET, so the length of the text is not the bound: the value is, checked as it grows.
    private static func digitsValue(_ digits: [Unicode.Scalar], _ negative: Bool) -> Int? {
        if digits.isEmpty { return nil }
        var value = 0
        for c in digits {
            guard c.value >= 0x30, c.value <= 0x39 else { return nil }
            value = value * 10 + Int(c.value - 0x30)
            if value > Int(Int32.max) + 1 { return nil }
        }
        if negative { value = -value }
        return value >= Int(Int32.min) && value <= Int(Int32.max) ? value : nil
    }

    /// `int.TryParse(text, NumberStyles.HexNumber, InvariantCulture)` for text of at most seven digits (no sign
    /// wrapping can happen), or nil.
    static func parseHex(_ text: String) -> Int? {
        let s = trimmed(text)
        if s.isEmpty || s.count > 7 { return nil }
        var value = 0
        for c in s {
            guard let digit = Int(String(c), radix: 16), c.isASCII else { return nil }
            value = value * 16 + digit
        }
        return value
    }

    /// The digits of ToString("0.##"): at most two decimals, the number first cut to 15 significant digits, then rounded
    /// half away from zero.
    static func twoDecimals(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        // d.dddddddddddddde+XX: fifteen significant digits and the decimal exponent.
        let scientific = String(format: "%.14e", abs(value))
        let parts = scientific.split(separator: "e")
        var digits = parts[0].filter { $0 != "." }.map { Int(String($0)) ?? 0 }
        let exponent = Int(parts[1]) ?? 0
        // Digits before the decimal point: exponent + 1, or none when the value is below 1.
        var integerCount = exponent + 1
        if integerCount < 0 {
            digits = [Int](repeating: 0, count: -integerCount) + digits
            integerCount = 0
        }
        while digits.count < integerCount + 3 { digits.append(0) }
        let keep = integerCount + 2
        var roundUp = digits[keep] >= 5
        digits = Array(digits[0..<keep])
        var index = keep - 1
        while roundUp {
            if index < 0 {
                digits.insert(1, at: 0)
                integerCount += 1
                roundUp = false
            } else if digits[index] == 9 {
                digits[index] = 0
                index -= 1
            } else {
                digits[index] += 1
                roundUp = false
            }
        }
        var whole = digits[0..<integerCount].map(String.init).joined()
        var fraction = digits[integerCount...].map(String.init).joined()
        while fraction.hasSuffix("0") { fraction.removeLast() }
        if whole.isEmpty { whole = "0" }
        let text = fraction.isEmpty ? whole : whole + "." + fraction
        return text == "0" ? sign + "0" : sign + text
    }
}
