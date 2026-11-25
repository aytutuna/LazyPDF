import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormData.cs: the values of a form in the four files people exchange them in.

public enum DataFormat: CaseIterable {
    case fdf, xfdf, csv, json

    public var fileExtension: String {
        switch self {
        case .fdf: return "fdf"
        case .xfdf: return "xfdf"
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

/// A data file that is not what its extension says: a table without a data row, JSON that is not an object of names and values.
public struct FormDataException: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum FormData {
    public static func format(of path: String) -> DataFormat? {
        switch (path as NSString).pathExtension.lowercased() {
        case "fdf": return .fdf
        case "xfdf": return .xfdf
        case "csv": return .csv
        case "json": return .json
        default: return nil
        }
    }

    public static func export(_ form: PdfForm, _ format: DataFormat, fileName: String) throws -> [UInt8] {
        switch format {
        case .fdf: return try PdfFdf.write(form.exportFdf(fileName))
        case .xfdf: return try PdfXfdf.write(form.exportFdf(fileName))
        // The mark lets Excel read Turkish letters.
        case .csv: return [0xEF, 0xBB, 0xBF] + Array(form.exportCsv().utf8)
        case .json: return toJson(form)
        }
    }

    /// Fills the form from a file. `rows` is how many data rows a CSV file had; only the first is used.
    public static func `import`(_ form: PdfForm, _ format: DataFormat, _ data: [UInt8]) throws -> (result: FormFillResult, rows: Int) {
        switch format {
        case .fdf:
            return (try form.importFdf(PdfFdf.read(data)), 1)
        case .xfdf:
            return (try form.importFdf(PdfXfdf.read(data)), 1)
        case .csv:
            let table = parseCsv(csvText(data))
            if table.count < 2 { throw FormDataException("The table has no data row.") }
            let values = zip(table[0], table[1]).filter { !$0.0.isEmpty }.map { ($0.0, Optional($0.1)) }
            return (try form.setValues(values), table.count - 1)
        case .json:
            return (try form.setValues(fromJson(data)), 1)
        }
    }

    // Excel saves a Turkish CSV in the ANSI code page unless it is told otherwise.
    private static func csvText(_ data: [UInt8]) -> String {
        var text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .windowsCP1254) ?? ""
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        return text
    }

    private static func toJson(_ form: PdfForm) -> [UInt8] {
        var seen = Set<String>()
        var lines: [String] = []
        for field in form.fields where field.kind != .pushButton && field.kind != .signature && !field.has(.noExport) {
            guard seen.insert(field.name).inserted else { continue }
            let value = field.selected.count > 1 ? field.selected.joined(separator: "; ") : field.value ?? ""
            lines.append("  " + quoted(field.name) + ": " + quoted(value))
        }
        let body = lines.isEmpty ? "{}" : "{\n" + lines.joined(separator: ",\n") + "\n}"
        return Array(body.utf8)
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func fromJson(_ data: [UInt8]) throws -> [(String, String?)] {
        var reader = JsonReader(data)
        guard case .object(let members) = try reader.readRoot() else {
            throw FormDataException("The file is not an object of names and values.")
        }
        var values: [(String, String?)] = []
        for (name, value) in members {
            switch value {
            case .string(let text), .raw(let text): values.append((name, text))
            case .array(let items): values.append((name, items.map(\.text).joined(separator: "; ")))
            default: break
            }
        }
        return values
    }

    // Comma, semicolon or tab, whichever the first line uses most; quotes may hold the separator and line breaks.
    static func parseCsv(_ text: String) -> [[String]] {
        let chars = Array(text.unicodeScalars)
        let end = chars.firstIndex { $0 == "\r" || $0 == "\n" } ?? chars.count
        let first = chars[..<end]
        var separator: Unicode.Scalar = ","
        var best = first.filter { $0 == "," }.count
        for candidate: Unicode.Scalar in [";", "\t"] {
            let count = first.filter { $0 == candidate }.count
            if count > best {
                best = count
                separator = candidate
            }
        }
        var rows: [[String]] = []
        var row: [String] = []
        var cell = String.UnicodeScalarView()
        var quoted = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c != "\"" {
                    cell.append(c)
                } else if i + 1 < chars.count, chars[i + 1] == "\"" {
                    cell.append("\"")
                    i += 1
                } else {
                    quoted = false
                }
            } else if c == "\"" {
                quoted = true
            } else if c == separator {
                row.append(String(cell))
                cell = String.UnicodeScalarView()
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(String(cell))
                cell = String.UnicodeScalarView()
                rows.append(row)
                row = []
            } else {
                cell.append(c)
            }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(String(cell))
            rows.append(row)
        }
        return rows
    }
}

// Reads a JSON value in file order, which JSONSerialization's dictionaries lose. Numbers and words keep the text they had in the
// file. A comment is skipped, as the Windows reader does.
private indirect enum JsonValue {
    case string(String)
    case raw(String)
    case array([JsonValue])
    case object([(String, JsonValue)])
    case null

    var text: String {
        switch self {
        case .string(let text), .raw(let text): return text
        default: return ""
        }
    }
}

private struct JsonReader {
    private let bytes: [UInt8]
    private var at = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readRoot() throws -> JsonValue {
        let value = try readValue(0)
        skip()
        if at < bytes.count { throw FormDataException("Unexpected text after the value.") }
        return value
    }

    private mutating func skip() {
        while at < bytes.count {
            let b = bytes[at]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                at += 1
            } else if b == 0x2F, at + 1 < bytes.count, bytes[at + 1] == 0x2F {
                while at < bytes.count, bytes[at] != 0x0A { at += 1 }
            } else if b == 0x2F, at + 1 < bytes.count, bytes[at + 1] == 0x2A {
                at += 2
                while at + 1 < bytes.count, !(bytes[at] == 0x2A && bytes[at + 1] == 0x2F) { at += 1 }
                at = min(at + 2, bytes.count)
            } else {
                return
            }
        }
    }

    private mutating func readValue(_ depth: Int) throws -> JsonValue {
        if depth > 64 { throw FormDataException("The file is nested too deeply.") }
        skip()
        guard at < bytes.count else { throw FormDataException("The file ends too soon.") }
        switch bytes[at] {
        case 0x7B: return try readObject(depth)
        case 0x5B: return try readArray(depth)
        case 0x22: return .string(try readString())
        default: return try readWord()
        }
    }

    private mutating func readObject(_ depth: Int) throws -> JsonValue {
        at += 1
        var members: [(String, JsonValue)] = []
        skip()
        if at < bytes.count, bytes[at] == 0x7D {
            at += 1
            return .object(members)
        }
        while true {
            skip()
            guard at < bytes.count, bytes[at] == 0x22 else { throw FormDataException("A name was expected.") }
            let name = try readString()
            skip()
            guard at < bytes.count, bytes[at] == 0x3A else { throw FormDataException("A colon was expected.") }
            at += 1
            members.append((name, try readValue(depth + 1)))
            skip()
            guard at < bytes.count else { throw FormDataException("The file ends too soon.") }
            if bytes[at] == 0x2C { at += 1; continue }
            if bytes[at] == 0x7D { at += 1; return .object(members) }
            throw FormDataException("A comma or a closing brace was expected.")
        }
    }

    private mutating func readArray(_ depth: Int) throws -> JsonValue {
        at += 1
        var items: [JsonValue] = []
        skip()
        if at < bytes.count, bytes[at] == 0x5D {
            at += 1
            return .array(items)
        }
        while true {
            items.append(try readValue(depth + 1))
            skip()
            guard at < bytes.count else { throw FormDataException("The file ends too soon.") }
            if bytes[at] == 0x2C { at += 1; continue }
            if bytes[at] == 0x5D { at += 1; return .array(items) }
            throw FormDataException("A comma or a closing bracket was expected.")
        }
    }

    private mutating func readWord() throws -> JsonValue {
        let start = at
        while at < bytes.count, !",]} \t\r\n".utf8.contains(bytes[at]) { at += 1 }
        let word = String(decoding: bytes[start..<at], as: UTF8.self)
        if word == "null" { return .null }
        if word == "true" || word == "false" { return .raw(word) }
        if let number = Double(word), number.isFinite, let first = word.first, first == "-" || first.isASCII && first.isNumber {
            return .raw(word)
        }
        throw FormDataException("The file is not JSON.")
    }

    private mutating func readString() throws -> String {
        at += 1
        var out: [UInt8] = []
        var units: [UInt16] = []
        func flush() {
            if !units.isEmpty {
                out += Array(String(decoding: units, as: UTF16.self).utf8)
                units = []
            }
        }
        while at < bytes.count {
            let b = bytes[at]
            at += 1
            if b == 0x22 {
                flush()
                return String(decoding: out, as: UTF8.self)
            }
            guard b == 0x5C else {
                flush()
                out.append(b)
                continue
            }
            guard at < bytes.count else { break }
            let e = bytes[at]
            at += 1
            switch e {
            case 0x75:
                guard at + 4 <= bytes.count, let unit = UInt16(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16) else {
                    throw FormDataException("A \\u escape needs four hex digits.")
                }
                units.append(unit)
                at += 4
            case 0x6E: flush(); out.append(0x0A)
            case 0x72: flush(); out.append(0x0D)
            case 0x74: flush(); out.append(0x09)
            case 0x62: flush(); out.append(0x08)
            case 0x66: flush(); out.append(0x0C)
            case 0x22, 0x5C, 0x2F: flush(); out.append(e)
            default: throw FormDataException("An escape in a string is not known.")
            }
        }
        throw FormDataException("A string was not closed.")
    }
}
