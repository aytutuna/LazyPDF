import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormCsv.cs: comma-separated values as RFC 4180 describes them, read with the delimiter a
// spreadsheet chose (comma, semicolon or tab). The text is walked in UTF-16 units, as the C# does.

enum FormCsv {
    private static let maxRows = 100_000
    private static let maxColumns = 10_000

    static func read(_ source: String) -> [[String]] {
        var text = Array(source.utf16)
        if text.first == 0xFEFF { text.removeFirst() }
        let delimiter = delimiter(of: text)
        var rows: [[String]] = []
        var row: [String] = []
        var cell: [UInt16] = []
        var quoted = false, wasQuoted = false
        var i = 0
        while i < text.count {
            let c = text[i]
            if quoted {
                if c != 0x22 {
                    cell.append(c)
                } else if i + 1 < text.count && text[i + 1] == 0x22 {
                    cell.append(0x22)
                    i += 1
                } else {
                    quoted = false
                }
            } else if c == 0x22 && cell.isEmpty {
                quoted = true
                wasQuoted = true
            } else if c == delimiter {
                endCell(&row, &cell)
                wasQuoted = false
            } else if c == 0x0D || c == 0x0A {
                if c == 0x0D && i + 1 < text.count && text[i + 1] == 0x0A { i += 1 }
                endCell(&row, &cell)
                if row.count > 1 || !(row.first ?? "").isEmpty || wasQuoted { rows.append(row) }
                row = []
                wasQuoted = false
                if rows.count >= maxRows { return rows }
            } else {
                cell.append(c)
            }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty || wasQuoted {
            endCell(&row, &cell)
            rows.append(row)
        }
        return rows
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map { quote($0) }.joined(separator: ",") + "\r\n" }.joined()
    }

    private static func endCell(_ row: inout [String], _ cell: inout [UInt16]) {
        if row.count < maxColumns { row.append(String(decoding: cell, as: UTF16.self)) }
        cell.removeAll()
    }

    private static func quote(_ value: String) -> String {
        let units = Array(value.utf16)
        let special = units.contains { $0 == 0x2C || $0 == 0x22 || $0 == 0x0D || $0 == 0x0A }
        if special || units.first == 0x20 || units.last == 0x20 {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // The first line decides: whichever of the three it has most of outside quotes.
    private static func delimiter(of text: [UInt16]) -> UInt16 {
        var comma = 0, semicolon = 0, tab = 0
        var quoted = false
        for c in text {
            if c == 0x22 {
                quoted.toggle()
            } else if !quoted && (c == 0x0D || c == 0x0A) {
                break
            } else if !quoted {
                if c == 0x2C { comma += 1 } else if c == 0x3B { semicolon += 1 } else if c == 0x09 { tab += 1 }
            }
        }
        if semicolon > comma && semicolon >= tab { return 0x3B }
        return tab > comma ? 0x09 : 0x2C
    }
}
