import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormScriptParser.cs: reads the text of an action's JavaScript when it is nothing but
// calls of the AF functions Acrobat writes for the standard formats, calculations and ranges. Anything else is not
// understood and not run. The text is walked in UTF-16 units, as the C# does.

/// An argument of a built-in call: a number, a string, a boolean, null or a list of those.
indirect enum FormArg {
    case number(Double)
    case text(String)
    case flag(Bool)
    case null
    case list([FormArg])
}

/// A call of one of the built-in form functions, its arguments as numbers, strings, booleans, null or lists of those.
struct FormCall {
    let name: String
    let args: [FormArg]

    func number(_ index: Int, _ fallback: Double = 0) -> Double {
        if index < args.count, case .number(let d) = args[index] { return d }
        return fallback
    }

    func text(_ index: Int, _ fallback: String = "") -> String {
        if index < args.count, case .text(let s) = args[index] { return s }
        return fallback
    }

    func flag(_ index: Int, _ fallback: Bool = false) -> Bool {
        if index < args.count, case .flag(let b) = args[index] { return b }
        return fallback
    }
}

struct FormScriptParser {
    private static let maxLength = 4096
    private static let maxCalls = 64
    private static let maxArgs = 256
    private static let maxDepth = 8

    private static let known: Set<String> = [
        "AFNumber_Format", "AFNumber_Keystroke", "AFPercent_Format", "AFPercent_Keystroke",
        "AFDate_Format", "AFDate_FormatEx", "AFDate_Keystroke", "AFDate_KeystrokeEx",
        "AFTime_Format", "AFTime_FormatEx", "AFTime_Keystroke", "AFTime_KeystrokeEx",
        "AFSpecial_Format", "AFSpecial_Keystroke", "AFSpecial_KeystrokeEx",
        "AFSimple_Calculate", "AFRange_Validate",
    ]

    private let text: [UInt16]
    private var at = 0

    private init(_ text: [UInt16]) {
        self.text = text
    }

    /// The calls in the text, or nil when it holds anything else.
    static func parse(_ source: String) -> [FormCall]? {
        let units = Array(source.utf16)
        if units.count > maxLength { return nil }
        var parser = FormScriptParser(units)
        var calls: [FormCall] = []
        while true {
            parser.skip()
            if parser.at >= units.count { return calls.isEmpty ? nil : calls }
            guard calls.count < maxCalls, let call = parser.call() else { return nil }
            calls.append(call)
            parser.skip()
            if parser.peek() == 0x3B { parser.at += 1 }
        }
    }

    private mutating func call() -> FormCall? {
        let name = identifier()
        skip()
        if !Self.known.contains(name) || peek() != 0x28 { return nil }
        at += 1
        if let args = arguments(0x29, 0) { return FormCall(name: name, args: args) }
        return nil
    }

    private mutating func arguments(_ close: UInt16, _ depth: Int) -> [FormArg]? {
        var args: [FormArg] = []
        skip()
        if peek() == close {
            at += 1
            return args
        }
        while args.count < Self.maxArgs {
            if depth > Self.maxDepth { return nil }
            guard let item = value(depth) else { return nil }
            args.append(item)
            skip()
            let c = peek()
            at += 1
            if c == close { return args }
            if c != 0x2C { return nil }
        }
        return nil
    }

    private mutating func value(_ depth: Int) -> FormArg? {
        skip()
        let c = peek()
        if c == 0x22 || c == 0x27 { return quoted(c) }
        if c == 0x5B {
            at += 1
            if let list = arguments(0x5D, depth + 1) { return .list(list) }
            return nil
        }
        if c == 0x2D || c == 0x2B || c == 0x2E || Self.isDigit(c) {
            let start = at
            at += 1
            while at < text.count, Self.isDigit(text[at]) || text[at] == 0x2E || text[at] == 0x65 || text[at] == 0x45 { at += 1 }
            let part = String(decoding: text[start..<at], as: UTF16.self)
            guard let number = InvariantNumbers.parseDouble(part) else { return nil }
            return .number(number)
        }
        let word = identifier()
        switch word {
        case "true": return .flag(true)
        case "false": return .flag(false)
        case "null": return .null
        case "new", "Array":
            if word == "new" {
                skip()
                if identifier() != "Array" { return nil }
            }
            skip()
            if peek() != 0x28 { return nil }
            at += 1
            if let list = arguments(0x29, depth + 1) { return .list(list) }
            return nil
        default:
            return nil
        }
    }

    private mutating func quoted(_ quote: UInt16) -> FormArg? {
        var units: [UInt16] = []
        at += 1
        while at < text.count {
            let c = text[at]
            at += 1
            if c == quote { return .text(String(decoding: units, as: UTF16.self)) }
            if c != 0x5C {
                units.append(c)
                continue
            }
            if at >= text.count { return nil }
            let e = text[at]
            at += 1
            if e == 0x75, at + 4 <= text.count,
               let code = InvariantNumbers.parseHex(String(decoding: text[at..<(at + 4)], as: UTF16.self)) {
                units.append(UInt16(truncatingIfNeeded: code))
                at += 4
            } else {
                switch e {
                case 0x6E: units.append(0x0A)
                case 0x74: units.append(0x09)
                case 0x72: units.append(0x0D)
                default: units.append(e)
                }
            }
        }
        return nil
    }

    private mutating func identifier() -> String {
        let start = at
        while at < text.count, Self.isAsciiLetterOrDigit(text[at]) || text[at] == 0x5F || text[at] == 0x24 { at += 1 }
        return String(decoding: text[start..<at], as: UTF16.self)
    }

    private func peek() -> UInt16 { at < text.count ? text[at] : 0 }

    private mutating func skip() {
        while at < text.count {
            if Self.isWhiteSpace(text[at]) {
                at += 1
            } else if text[at] == 0x2F, at + 1 < text.count, text[at + 1] == 0x2F {
                at = text[at...].firstIndex(of: 0x0A) ?? text.count
            } else if text[at] == 0x2F, at + 1 < text.count, text[at + 1] == 0x2A {
                at = Self.indexOfCommentEnd(text, at + 2).map { $0 + 2 } ?? text.count
            } else {
                break
            }
        }
    }

    private static func indexOfCommentEnd(_ text: [UInt16], _ from: Int) -> Int? {
        var i = from
        while i + 1 < text.count {
            if text[i] == 0x2A && text[i + 1] == 0x2F { return i }
            i += 1
        }
        return nil
    }

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    static func isAsciiLetterOrDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    /// char.IsWhiteSpace.
    static func isWhiteSpace(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isWhitespace
    }
}
