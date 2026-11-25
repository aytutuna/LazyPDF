import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchNames.cs. The formats after a colon are the .NET ones that are in use: 0 padding
// for {n} (also D3), and y M d H h m s f tt with quoted text for {date}. A format that does not fit stays as typed, as the
// token of a format .NET refuses does.

enum BatchNames {
    /// The file name for a result. Characters the other platforms do not allow in a name become underscores.
    static func apply(_ template: String, _ name: String, _ number: Int, _ date: DateTimeOffset) -> String {
        var text = replaceTokens(template.isEmpty ? "{name}" : template) { token, format in
            switch token {
            case "name": return name
            case "n": return pad(number, format)
            default: return stamp(date, format.isEmpty ? "yyyy-MM-dd" : format)
            }
        }
        let bad = Set("\\/:*?\"<>|")
        text = String(text.map { bad.contains($0) || ($0.asciiValue ?? 32) < 32 ? "_" : $0 })
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        if text.isEmpty { text = name }
        return text.lowercased().hasSuffix(".pdf") ? text : text + ".pdf"
    }

    // {name}, {n}, {date}, each with an optional :format; a token that fails stays as it was written.
    private static func replaceTokens(_ template: String, _ replace: (String, String) -> String?) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let tail = rest[rest.index(after: open)...]
            if let close = tail.firstIndex(of: "}"), let token = parse(String(tail[..<close])), let done = replace(token.name, token.format) {
                result += done
                rest = tail[tail.index(after: close)...]
            } else {
                result.append("{")
                rest = tail
            }
        }
        return result + rest
    }

    private static func parse(_ body: String) -> (name: String, format: String)? {
        for name in ["name", "n", "date"] {
            if body == name { return (name, "") }
            if body.hasPrefix(name + ":"), !body.dropFirst(name.count + 1).contains("{") { return (name, String(body.dropFirst(name.count + 1))) }
        }
        return nil
    }

    private static func pad(_ number: Int, _ format: String) -> String? {
        if format.isEmpty { return String(number) }
        let width: Int
        if format.allSatisfy({ $0 == "0" }) {
            width = format.count
        } else if let first = format.first, "Dd".contains(first), let digits = Int(format.dropFirst()) {
            width = digits
        } else {
            return nil
        }
        let magnitude = String(number.magnitude)
        return (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - magnitude.count)) + magnitude
    }

    private static func stamp(_ date: DateTimeOffset, _ format: String) -> String? {
        var out = ""
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var run = 1
            while i + run < chars.count, chars[i + run] == c { run += 1 }
            switch c {
            case "y": out += run >= 4 ? four(date.year) : two(date.year % 100)
            case "M" where run <= 2: out += run == 2 ? two(date.month) : String(date.month)
            case "d" where run <= 2: out += run == 2 ? two(date.day) : String(date.day)
            case "H" where run <= 2: out += run == 2 ? two(date.hour) : String(date.hour)
            case "h" where run <= 2:
                let hour = date.hour % 12 == 0 ? 12 : date.hour % 12
                out += run == 2 ? two(hour) : String(hour)
            case "m" where run <= 2: out += run == 2 ? two(date.minute) : String(date.minute)
            case "s" where run <= 2: out += run == 2 ? two(date.second) : String(date.second)
            case "t" where run == 2: out += date.hour < 12 ? "AM" : "PM"
            case "'":
                guard let end = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                out += String(chars[(i + 1)..<end])
                i = end + 1
                continue
            case "-", "_", ".", " ", "/", ":", ",": out += String(repeating: c, count: run)
            default:
                if c.isLetter { return nil }
                out += String(repeating: c, count: run)
            }
            i += run
        }
        return out
    }

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    private static func four(_ n: Int) -> String { String(repeating: "0", count: max(0, 4 - String(n).count)) + String(n) }
}
