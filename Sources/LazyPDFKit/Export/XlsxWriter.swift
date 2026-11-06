import Foundation

// Twin of windows/LazyPDF.Core/Export/XlsxWriter.cs: the Excel workbook (.xlsx) of an `ExportDocument`. Each table is a
// sheet; a document with no table gets one sheet per page holding the page's text laid out in rows and columns by
// position. Cells that read as numbers are numbers.
//
// A number is written as `double.ToString("R")` writes it (the shortest text that reads back, in scientific form from
// 1E+15 and under 1E-05), by `roundTrip`. Sheet names are compared as OrdinalIgnoreCase does, by simple upper case.

private typealias Xml = ExportXml

public enum XlsxWriter {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let maxSheets = 1000
    private static let maxColumns = 64
    private static let columnGap = 6.0
    private static let maxSheetRows = 1048576, maxSheetColumns = 16384, maxCellChars = 32767

    public static func make(_ document: ExportDocument) throws -> [UInt8] {
        var sheets: [(name: String, rows: [[String]])] = []
        let tables = !document.tables.isEmpty
        for page in document.pages {
            if tables {
                var n = 0
                for case let table as ExportTable in page.blocks {
                    n += 1
                    sheets.append((ExportText.table(n, page.index + 1), table.rows))
                }
            } else if !page.lines.isEmpty {
                sheets.append((ExportText.page(page.index + 1), grid(page.lines)))
            }
            if sheets.count >= maxSheets { break }
        }
        if sheets.isEmpty { sheets.append(("Sheet1", [])) }

        var names = Set<String>()
        let unique = sheets.map { Self.unique(sheetName($0.name), &names) }

        var types = Xml.header
        types += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in 0..<sheets.count {
            types += "<Override PartName=\"/xl/worksheets/sheet\(Xml.i(i + 1)).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        types += "</Types>"

        var book = Xml.header
        book += "<workbook xmlns=\"\(main)\" xmlns:r=\"\(officeRel)\"><sheets>"
        var rels = Xml.header
        rels += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 0..<sheets.count {
            book += "<sheet name=\"\(Xml.escape(unique[i]))\" sheetId=\"\(Xml.i(i + 1))\" r:id=\"rId\(Xml.i(i + 1))\"/>"
            rels += "<Relationship Id=\"rId\(Xml.i(i + 1))\" Type=\"\(officeRel)/worksheet\" Target=\"worksheets/sheet\(Xml.i(i + 1)).xml\"/>"
        }
        book += "</sheets></workbook>"
        rels += "<Relationship Id=\"rId\(Xml.i(sheets.count + 1))\" Type=\"\(officeRel)/styles\" Target=\"styles.xml\"/></Relationships>"

        let rootRels = Xml.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        var styles = Xml.header
        styles += "<styleSheet xmlns=\"\(main)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
        styles += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        styles += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        styles += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        styles += "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        styles += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"top\"/></xf></cellXfs>"
        styles += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"

        var entries: [ExportZipEntry] = [
            ExportZipEntry("[Content_Types].xml", Xml.utf8(types)),
            ExportZipEntry("_rels/.rels", Xml.utf8(rootRels)),
            ExportZipEntry("xl/workbook.xml", Xml.utf8(book)),
            ExportZipEntry("xl/_rels/workbook.xml.rels", Xml.utf8(rels)),
            ExportZipEntry("xl/styles.xml", Xml.utf8(styles)),
        ]
        for i in 0..<sheets.count { entries.append(ExportZipEntry("xl/worksheets/sheet\(i + 1).xml", Xml.utf8(sheet(sheets[i].rows)))) }
        return try ExportZip.make(entries)
    }

    private static func sheet(_ all: [[String]]) -> String {
        let rows = all.count > maxSheetRows ? Array(all[0..<maxSheetRows]) : all
        let columns = rows.isEmpty ? 1 : min(max(rows.map { $0.count }.max() ?? 1, 1), maxSheetColumns)
        var sb = Xml.header
        sb += "<worksheet xmlns=\"\(main)\"><dimension ref=\"A1:\(column(columns - 1))\(Xml.i(max(1, rows.count)))\"/><cols>"
        for c in 0..<columns {
            var longest = 0
            for r in rows where c < r.count { longest = max(longest, ExportString.longestLine(r[c])) }
            sb += "<col min=\"\(Xml.i(c + 1))\" max=\"\(Xml.i(c + 1))\" width=\"\(Xml.i(min(max(longest + 2, 8), 60)))\" customWidth=\"1\"/>"
        }
        sb += "</cols><sheetData>"
        for r in 0..<rows.count {
            sb += "<row r=\"\(Xml.i(r + 1))\">"
            for c in 0..<min(rows[r].count, columns) {
                var text = rows[r][c]
                if text.isEmpty { continue }
                if text.utf16.count > maxCellChars { text = ExportString.prefix(text, maxCellChars) }
                let at = column(c) + Xml.i(r + 1)
                if let number = tryNumber(text) {
                    sb += "<c r=\"\(at)\"><v>\(roundTrip(number))</v></c>"
                } else {
                    let style = text.unicodeScalars.contains("\n") ? " s=\"1\"" : ""
                    sb += "<c r=\"\(at)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(Xml.escape(text))</t></is></c>"
                }
            }
            sb += "</row>"
        }
        sb += "</sheetData></worksheet>"
        return sb
    }

    // Lines on one row of the page share a spreadsheet row; their left edges, clustered, are the columns.
    private static func grid(_ lines: [ExportTextLine]) -> [[String]] {
        let middle: (ExportTextLine) -> Double = { $0.bounds.y + $0.bounds.height / 2 }
        let ordered = ExportSort.stable(lines.filter { !ExportTrim.both($0.text).isEmpty }) { ExportSort.before(middle($0), middle($1)) }
        var rows: [[ExportTextLine]] = []
        for line in ordered {
            let mid = middle(line)
            if let first = rows.last?.first, abs(mid - middle(first)) <= 0.5 * line.bounds.height {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        var starts: [Double] = []
        for left in ExportSort.stable(ordered.map { $0.bounds.x }, { ExportSort.before($0, $1) }) {
            if let last = starts.last, left - last <= columnGap { continue }
            starts.append(left)
        }
        let aligned = starts.count <= maxColumns
        var grid: [[String]] = []
        for row in rows {
            var cells: [String] = []
            var lengths: [Int] = []
            var index = 0
            for line in ExportSort.stable(row, { ExportSort.before($0.bounds.x, $1.bounds.x) }) {
                var column = aligned ? (starts.lastIndex { $0 <= line.bounds.x + columnGap / 2 } ?? -1) : min(index, maxSheetColumns - 1)
                while cells.count <= max(column, 0) {
                    cells.append("")
                    lengths.append(0)
                }
                column = max(column, 0)
                let text = ExportTrim.both(line.text)
                if lengths[column] == 0 {
                    cells[column] = text
                    lengths[column] = text.utf16.count
                } else if lengths[column] < maxCellChars {
                    cells[column] += " " + text
                    lengths[column] += 1 + text.utf16.count
                }
                index += 1
            }
            grid.append(cells)
        }
        return grid
    }

    /// A cell that is a number: optional sign, digits with thousands separators and a decimal separator, either "1,234.56"
    /// or "1.234,56". A single comma before exactly three digits is a thousands separator, a single dot a decimal one. A
    /// whole number with a leading zero ("007") is text, like anything over 15 digits.
    static func tryNumber(_ text: String) -> Double? {
        let t = Array(ExportTrim.both(text).utf16)
        let start = !t.isEmpty && (t[0] == 0x2D || t[0] == 0x2B) ? 1 : 0
        let length = t.count - start
        if length < 1 || length > 24 { return nil }
        let dot: UInt16 = 0x2E, comma: UInt16 = 0x2C
        func digit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        for c in t[start...] where !(digit(c) || c == dot || c == comma) { return nil }
        if !digit(t[t.count - 1]) || !digit(t[start]) { return nil }
        let body = Array(t[start...])
        let dots = body.filter { $0 == dot }.count, commas = body.filter { $0 == comma }.count
        var mark: UInt16?, group: UInt16?
        if dots > 0 && commas > 0 {
            let lastDot = body.lastIndex(of: dot) ?? -1, lastComma = body.lastIndex(of: comma) ?? -1
            mark = lastDot > lastComma ? dot : comma
            group = mark == dot ? comma : dot
        } else if dots == 1 {
            mark = dot
        } else if commas == 1 && isGrouped(body, comma) {
            group = comma
        } else if commas == 1 {
            mark = comma
        } else if dots > 1 {
            group = dot
        } else if commas > 1 {
            group = comma
        }

        var integer = body, fraction: [UInt16] = []
        if let m = mark, let at = body.lastIndex(of: m) {
            integer = Array(body[..<at])
            fraction = Array(body[(at + 1)...])
        }
        if let g = group {
            if !isGrouped(integer, g) { return nil }
            integer = integer.filter { $0 != g }
        }
        if !integer.allSatisfy(digit) || !fraction.allSatisfy(digit) || integer.count + fraction.count > 15 { return nil }
        if mark == nil && integer.count > 1 && integer[0] == 0x30 { return nil }
        let digits = String(decoding: integer, as: UTF16.self) + (fraction.isEmpty ? "" : "." + String(decoding: fraction, as: UTF16.self))
        guard let value = Double(digits) else { return nil }
        return t[0] == 0x2D ? -value : value
    }

    // One to three digits, then groups of exactly three.
    private static func isGrouped(_ text: [UInt16], _ mark: UInt16) -> Bool {
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        return parts.count > 1 && parts[0].count >= 1 && parts[0].count <= 3 && parts.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// `double.ToString("R")` under the invariant culture: the shortest digits that read back, fixed from 1E-04 up to
    /// below 1E+15 and scientific outside.
    static func roundTrip(_ value: Double) -> String {
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        let shortest = "\(abs(value))"
        let parts = shortest.split(separator: "e")
        let mantissa = String(parts[0])
        var exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var digits = Array(mantissa.filter { $0 != "." })
        var point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        while digits.count > 1 && digits[0] == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1 && digits[digits.count - 1] == "0" { digits.removeLast() }
        exponent += point - 1
        let text = String(digits)
        if exponent >= 15 || exponent < -4 {
            let tail = text.count > 1 ? "." + String(text.dropFirst()) : ""
            let magnitude = abs(exponent) < 10 ? "0\(abs(exponent))" : "\(abs(exponent))"
            let direction = exponent < 0 ? "-" : "+"
            return sign + String(text.prefix(1)) + tail + "E" + direction + magnitude
        }
        if exponent >= 0 {
            let whole = exponent + 1
            if text.count <= whole { return sign + text + String(repeating: "0", count: whole - text.count) }
            return sign + String(text.prefix(whole)) + "." + String(text.dropFirst(whole))
        }
        return sign + "0." + String(repeating: "0", count: -exponent - 1) + text
    }

    private static func column(_ index: Int) -> String {
        var letters: [Character] = []
        var n = index + 1
        while n > 0 {
            letters.insert(Character(Unicode.Scalar(UInt8(65 + (n - 1) % 26))), at: 0)
            n = (n - 1) / 26
        }
        return String(letters)
    }

    private static func sheetName(_ name: String) -> String {
        var clean = String.UnicodeScalarView()
        for c in name.unicodeScalars { clean.append("[]:*?/\\".unicodeScalars.contains(c) ? " " : c) }
        var text = Array(ExportTrim.both(String(clean)).unicodeScalars)
        while text.first == "'" { text.removeFirst() }
        while text.last == "'" { text.removeLast() }
        var result = String(String.UnicodeScalarView(text))
        if result.utf16.count > 31 { result = ExportString.prefix(result, 31) }
        return result.isEmpty ? "Sheet" : result
    }

    // OrdinalIgnoreCase: by the simple upper case mapping of each character.
    private static func folded(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for c in name.unicodeScalars {
            let upper = c.properties.uppercaseMapping.unicodeScalars
            out.append(upper.count == 1 ? (upper.first ?? c) : c)
        }
        return String(out)
    }

    private static func unique(_ name: String, _ taken: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while !taken.insert(folded(candidate)).inserted {
            let suffix = " " + Xml.i(n)
            candidate = ExportString.prefix(name, 31 - suffix.utf16.count) + suffix
            n += 1
        }
        return candidate
    }
}
