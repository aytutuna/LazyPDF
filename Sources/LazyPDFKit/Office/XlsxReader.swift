import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/XlsxReader.cs.

/// Reads an .xlsx package into an `XlsxWorkbook`: the visible sheets with cell text already formatted by the number formats,
/// column widths and row heights in points, merged cells and print setup names. Formulas are never calculated; the value the
/// file cached is shown. What it does not carry over is counted in `XlsxWorkbook.skipped`.
final class XlsxReader {
    static let m = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private struct SharedString {
        let text: String
        let firstRun: OfficeXmlElement?
        let rich: Bool
    }

    private let package: OpcPackage
    private let limits: XlsxLimits
    private var skipped: [String: Int] = [:]
    private var strings: [SharedString] = []
    private var theme = DocxTheme()
    private var styles = XlsxStyles()
    private var date1904 = false
    private var cells = 0
    private var totalText = 0

    private init(_ package: OpcPackage, _ limits: XlsxLimits) {
        self.package = package
        self.limits = limits
    }

    static func read(_ data: [UInt8], _ limits: XlsxLimits = .standard) throws -> XlsxWorkbook {
        if data.count >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0 {
            throw PdfReadException(.unsupported, "This is an Excel 97-2003 file. Save it as .xlsx first.")
        }
        return try XlsxReader(try OpcPackage.open(data), limits).run()
    }

    private static func contains(_ text: String, _ part: String) -> Bool {
        let t = Array(text.utf8), p = Array(part.utf8)
        if p.isEmpty { return true }
        if t.count < p.count { return false }
        for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
        return false
    }

    private static func endsWith(_ text: String, _ suffix: String) -> Bool {
        let t = Array(text.utf8), s = Array(suffix.utf8)
        return t.count >= s.count && Array(t[(t.count - s.count)...]) == s
    }

    private func run() throws -> XlsxWorkbook {
        let m = Self.m, r = Self.r
        guard let main = try package.relationships("").first(where: { $0.type == OpcPackage.officeDocument })?.target else {
            throw PdfReadException.damaged("The file has no main workbook part.")
        }
        if !package.contains(main) { throw PdfReadException.damaged("The package has no part \(main).") }
        let type = package.contentType(main) ?? ""
        if Self.contains(type, "binary") { throw PdfReadException(.unsupported, "This is an Excel binary (.xlsb) file. Save it as .xlsx first.") }
        if !Self.contains(type, "spreadsheetml") && !Self.contains(type, "ms-excel") {
            throw PdfReadException(.unsupported, "The file is not an Excel workbook.")
        }
        let root = try package.xml(main)
        if root.uri != m || root.name != "workbook" { throw PdfReadException(.unsupported, "The workbook is not in the Excel 2007 format.") }

        let relationships = try package.relationships(main)
        theme = DocxTheme.read(try part(relationships, r + "/theme"))
        styles = try XlsxStylesReader.read(try part(relationships, r + "/styles"), theme, limits)
        date1904 = XlsxParse.flag(root.child(m, "workbookPr")?.attribute("date1904"), false)
        try readSharedStrings(try part(relationships, r + "/sharedStrings"))

        let workbook = XlsxWorkbook(date1904: date1904, styles: styles)
        var byIndex: [Int: XlsxSheet] = [:]
        let entries = root.child(m, "sheets")?.elements(m, "sheet") ?? []
        if entries.count > limits.maxSheets { throw PdfReadException(.unsupported, "The workbook has more than \(limits.maxSheets) sheets.") }
        for (i, entry) in entries.enumerated() {
            let state = entry.attribute("state") ?? "visible"
            if state == "hidden" || state == "veryHidden" {
                skip(XlsxSkipped.hiddenSheet)
                continue
            }
            let id = entry.attribute(r, "id")
            guard let relationship = relationships.first(where: { $0.id == id }), package.contains(relationship.target) else {
                skip(XlsxSkipped.otherSheet)
                continue
            }
            if Self.endsWith(relationship.type, "/chartsheet") {
                skip(XlsxSkipped.chartSheet)
                continue
            }
            if !Self.endsWith(relationship.type, "/worksheet") {
                skip(XlsxSkipped.otherSheet)
                continue
            }
            let sheet = try readSheet(entry.attribute("name") ?? "Sheet\(i + 1)", relationship.target)
            workbook.sheets.append(sheet)
            byIndex[i] = sheet
        }
        readNames(root.child(m, "definedNames"), byIndex)
        for kind in skipped.keys.sorted() { workbook.skipped.append(SkippedFeature(kind, skipped[kind]!)) }
        return workbook
    }

    private func part(_ relationships: [OpcRelationship], _ type: String) throws -> OfficeXmlElement? {
        guard let target = relationships.first(where: { $0.type == type })?.target, package.contains(target) else { return nil }
        return try package.xml(target)
    }

    private func skip(_ kind: String, _ count: Int = 1) { skipped[kind, default: 0] += count }

    // Text

    private static func isHex(_ c: UInt16) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }

    /// Replaces the _xHHHH_ escapes Excel writes for characters XML cannot hold; escapes that stand for half a surrogate pair stay as written.
    private static func unescape(_ units: [UInt16]) -> [UInt16] {
        var o: [UInt16] = []
        o.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if units[i] == 0x5F && i + 6 < units.count && units[i + 1] == 0x78 && units[i + 6] == 0x5F
                && units[(i + 2)...(i + 5)].allSatisfy(isHex),
               let code = UInt16(String(decoding: units[(i + 2)...(i + 5)], as: UTF16.self), radix: 16), code < 0xD800 || code > 0xDFFF {
                o.append(code)
                i += 7
            } else {
                o.append(units[i])
                i += 1
            }
        }
        return o
    }

    private func limited(_ text: String) throws -> String {
        var units = Self.unescape(Array(text.utf16))
        if units.count > limits.maxTextLength {
            var cut = limits.maxTextLength
            if units[cut - 1] >= 0xD800 && units[cut - 1] <= 0xDBFF { cut -= 1 }
            units = Array(units[..<cut])
            skip(XlsxSkipped.longText)
        }
        totalText += units.count
        if totalText > limits.maxTotalText { throw PdfReadException(.unsupported, "The workbook holds too much text.") }
        return String(decoding: units, as: UTF16.self)
    }

    private func readString(_ si: OfficeXmlElement) throws -> SharedString {
        let m = Self.m
        let runs = si.elements(m, "r")
        if runs.isEmpty { return SharedString(text: try limited(si.child(m, "t")?.text ?? ""), firstRun: nil, rich: false) }
        let text = runs.map { $0.child(m, "t")?.text ?? "" }.joined()
        return SharedString(text: try limited(text), firstRun: runs[0].child(m, "rPr"), rich: true)
    }

    private func readSharedStrings(_ root: OfficeXmlElement?) throws {
        guard let root, root.uri == Self.m, root.name == "sst" else { return }
        for si in root.elements(Self.m, "si") {
            if strings.count >= limits.maxSharedStrings { throw PdfReadException(.unsupported, "The workbook has too many shared strings.") }
            strings.append(try readString(si))
        }
    }

    // Sheets

    private static func points(_ pixels: Double) -> Double { pixels * 0.75 }

    private func columnPixels(_ width: Double) -> Double {
        let mdw = Double(styles.maxDigitWidth)
        return ((256 * width + (128.0 / mdw).rounded(.towardZero)) / 256 * mdw).rounded(.towardZero)
    }

    private func readSheet(_ name: String, _ partName: String) throws -> XlsxSheet {
        let m = Self.m
        let root = try package.xml(partName)
        if root.uri != m || root.name != "worksheet" { throw PdfReadException.damaged("The part \(partName) is not a worksheet.") }
        let sheet = XlsxSheet(name: name)

        let format = root.child(m, "sheetFormatPr")
        let baseWidth = XlsxParse.double(format?.attribute("baseColWidth")) ?? 8
        if let stated = XlsxParse.double(format?.attribute("defaultColWidth")), stated > 0, stated <= 255 {
            sheet.defaultColumnWidth = Self.points(columnPixels(stated))
        } else {
            sheet.defaultColumnWidth = Self.points(((min(baseWidth, 255) * Double(styles.maxDigitWidth) + 5) / 8).rounded(.up) * 8)
        }
        if let h = XlsxParse.double(format?.attribute("defaultRowHeight")), h > 0, h <= 409.5 { sheet.defaultRowHeight = h }

        for c in root.child(m, "cols")?.elements(m, "col") ?? [] {
            guard let first = XlsxParse.int(c.attribute("min")), var last = XlsxParse.int(c.attribute("max")) else { continue }
            last = min(last, XlsxLimits.maxColumn)
            if first < 1 || first > last || sheet.columns.count >= XlsxLimits.maxColumn { continue }
            var width = sheet.defaultColumnWidth
            if let w = XlsxParse.double(c.attribute("width")), w >= 0, w <= 255 { width = Self.points(columnPixels(w)) }
            sheet.columns.append(XlsxColumns(first: first, last: last, width: width, hidden: XlsxParse.flag(c.attribute("hidden"), false)))
        }

        var rows: [Int: XlsxRow] = [:]
        var previousRow = 0
        for rowElement in root.child(m, "sheetData")?.elements(m, "row") ?? [] {
            let index = XlsxParse.int(rowElement.attribute("r")) ?? previousRow + 1
            if index < 1 || index > XlsxLimits.maxRow { throw PdfReadException.damaged("A row number is outside the sheet.") }
            previousRow = index
            let row: XlsxRow
            if let known = rows[index] {
                row = known
            } else {
                row = XlsxRow(index)
                rows[index] = row
            }
            if let h = XlsxParse.double(rowElement.attribute("ht")), h >= 0, h <= 409.5 { row.height = h }
            if XlsxParse.flag(rowElement.attribute("hidden"), false) { row.hidden = true }
            try readCells(rowElement, row)
        }
        for index in rows.keys.sorted() {
            let row = rows[index]!
            if !row.cells.isEmpty || row.height != nil || row.hidden { sheet.rows.append(row) }
        }

        try readMerges(root.child(m, "mergeCells"), sheet)
        return sheet
    }

    private func readCells(_ rowElement: OfficeXmlElement, _ row: XlsxRow) throws {
        var previous = 0
        var sorted = true
        for c in rowElement.elements(Self.m, "c") {
            let column = XlsxRef.cell(c.attribute("r"))?.column ?? previous + 1
            previous = column
            if column < 1 || column > XlsxLimits.maxColumn {
                skip(XlsxSkipped.cellOutsideGrid)
                continue
            }
            guard let cell = try readCell(c, column) else { continue }
            cells += 1
            if cells > limits.maxCells { throw PdfReadException(.unsupported, "The workbook has more than \(limits.maxCells) cells.") }
            if let last = row.cells.last, last.column >= column { sorted = false }
            row.cells.append(cell)
        }
        if sorted { return }
        let ordered = row.cells.enumerated().sorted { ($0.element.column, $0.offset) < ($1.element.column, $1.offset) }.map { $0.element }
        row.cells = []
        for cell in ordered {
            if let last = row.cells.last, last.column == cell.column {
                row.cells[row.cells.count - 1] = cell
            } else {
                row.cells.append(cell)
            }
        }
    }

    /// The cell, or nil for an empty one with nothing to draw.
    private func readCell(_ c: OfficeXmlElement, _ column: Int) throws -> XlsxCell? {
        let m = Self.m
        var style = 0
        if let s = XlsxParse.int(c.attribute("s")), s < styles.xfs.count { style = s }
        let xf = styles.xf(style)
        let type = c.attribute("t") ?? "n"
        let value = c.child(m, "v")?.text
        let formula = c.child(m, "f") != nil

        var kind = XlsxCellKind.blank
        var text = ""
        var color: Int?
        var rich: XlsxFont?
        let numberFormat = styles.format(xf.numberFormatId)

        func number(_ v: Double) {
            let result = numberFormat.format(v, date1904: date1904)
            (kind, text, color) = (.number, result.text, result.color)
        }

        func plain(_ raw: String) {
            let result = numberFormat.formatText(raw)
            (kind, text, color) = (.text, result.text, result.color)
        }

        func shared(_ s: SharedString) {
            plain(s.text)
            if !s.rich { return }
            skip(XlsxSkipped.richText)
            rich = XlsxStylesReader.runFont(s.firstRun, styles.fonts[min(xf.font, styles.fonts.count - 1)], theme)
        }

        switch type {
        case "s" where value != nil:
            if let at = XlsxParse.int(XlsxParse.trim(value!)), at < strings.count { shared(strings[at]) }
        case "inlineStr" where c.child(m, "is") != nil:
            shared(try readString(c.child(m, "is")!))
        case "str" where value != nil:
            plain(try limited(value!))
        case "b" where value != nil:
            (kind, text) = (.bool, XlsxParse.trim(value!) == "1" ? "TRUE" : "FALSE")
        case "e" where value != nil:
            (kind, text) = (.error, try limited(value!))
        case "d" where value != nil:
            if let serial = isoDate(Array(XlsxParse.trim(value!).utf16)) { number(serial) } else { plain(try limited(value!)) }
        case "n" where value != nil:
            if let n = XlsxParse.double(XlsxParse.trim(value!)) { number(n) }
        default:
            break
        }

        if formula && kind == .blank && value == nil && type != "inlineStr" { skip(XlsxSkipped.formulaWithoutValue) }
        if kind == .blank {
            let fill = xf.fill < styles.fills.count ? styles.fills[xf.fill] : nil
            let border = xf.border < styles.borders.count ? styles.borders[xf.border] : nil
            let hasBorder = border.map { $0.left != nil || $0.right != nil || $0.top != nil || $0.bottom != nil } ?? false
            if fill?.color == nil && !hasBorder { return nil }
        } else if xf.rotated {
            skip(XlsxSkipped.textRotation)
        }
        if xf.fill < styles.fills.count && styles.fills[xf.fill].unsupported { skip(XlsxSkipped.fillPattern) }
        return XlsxCell(column: column, style: style, kind: kind, text: text, color: color, richFont: rich)
    }

    private static func split(_ s: [UInt16], _ separator: UInt16) -> [[UInt16]] {
        s.split(separator: separator, omittingEmptySubsequences: false).map { Array($0) }
    }

    /// The serial number of an ISO 8601 date, time or date and time (t="d" cells), in the workbook's date system.
    private func isoDate(_ input: [UInt16]) -> Double? {
        var s = input
        if s.last == 0x5A { s.removeLast() }
        let halves = Self.split(s, 0x54)
        if halves.count > 2 { return nil }
        let date: [UInt16]? = halves.count == 2 ? halves[0] : halves[0].contains(0x3A) ? nil : halves[0]
        let time: [UInt16]? = halves.count == 2 ? halves[1] : date == nil ? halves[0] : nil
        func int(_ u: [UInt16]) -> Int? { XlsxParse.int(String(decoding: u, as: UTF16.self)) }
        var days = 0.0
        if let date {
            let d = Self.split(date, 0x2D)
            if d.count != 3 || d[0].count != 4 || d[1].count != 2 || d[2].count != 2 { return nil }
            guard let year = int(d[0]), let month = int(d[1]), let day = int(d[2]) else { return nil }
            if month < 1 || month > 12 || day < 1 || day > 31 { return nil }
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            days = Double(era * 146097 + doe - 719468 + (date1904 ? 24107 : 25569))
            if !date1904 && days < 61 { days -= 1 }
            if days < 0 { return nil }
        }
        guard let time else { return days }
        let t = Self.split(time, 0x3A)
        if t.count < 2 || t.count > 3 { return nil }
        guard let h = int(t[0]), let mi = int(t[1]) else { return nil }
        let sec = t.count == 3 ? XlsxParse.double(String(decoding: t[2], as: UTF16.self)) ?? -1 : 0
        if h > 23 || mi > 59 || sec < 0 || sec >= 60 { return nil }
        return days + (Double(h * 3600 + mi * 60) + sec) / 86400
    }

    private func readMerges(_ merges: OfficeXmlElement?, _ sheet: XlsxSheet) throws {
        for e in merges?.elements(Self.m, "mergeCell") ?? [] {
            guard let range = XlsxRef.range(e.attribute("ref")) else { continue }
            if range.firstRow == range.lastRow && range.firstColumn == range.lastColumn { continue }
            if sheet.merges.count >= limits.maxMergedRanges { throw PdfReadException(.unsupported, "The sheet has too many merged cells.") }
            sheet.merges.append(range)
        }
    }

    // Print areas and titles

    private func readNames(_ names: OfficeXmlElement?, _ sheets: [Int: XlsxSheet]) {
        var seen = 0
        for n in names?.elements(Self.m, "definedName") ?? [] {
            seen += 1
            if seen > limits.maxDefinedNames { break }
            let name = n.attribute("name")
            guard name == "_xlnm.Print_Area" || name == "_xlnm.Print_Titles" else { continue }
            guard let id = XlsxParse.int(n.attribute("localSheetId")), let sheet = sheets[id] else { continue }
            for part in XlsxRef.splitList(Array(n.text.utf16)) {
                let reference = XlsxRef.afterSheet(part)
                if name == "_xlnm.Print_Area" {
                    if let range = XlsxRef.range(reference) { sheet.printArea.append(range) }
                } else if let columns = XlsxRef.columns(reference) {
                    sheet.titleColumns = columns
                } else if let rows = XlsxRef.rows(reference) {
                    sheet.titleRows = rows
                }
            }
        }
    }
}

extension XlsxParse {
    /// Removes the spaces, tabs and line ends XML allows around a value; the C# engine does the same.
    static func trim(_ text: String) -> String {
        let units = Array(text.utf16)
        func blank(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        var start = 0, end = units.count
        while start < end && blank(units[start]) { start += 1 }
        while end > start && blank(units[end - 1]) { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }
}

/// Cell references in A1 style, with or without the dollar signs.
enum XlsxRef {
    private struct Part {
        let column: Int
        let row: Int
        let hasRow: Bool
        let hasColumn: Bool
    }

    private static func split(_ text: ArraySlice<UInt16>) -> Part? {
        let t = Array(text)
        var i = 0
        if i < t.count && t[i] == 0x24 { i += 1 }
        var letters = 0, column = 0
        while i < t.count && ((t[i] >= 0x41 && t[i] <= 0x5A) || (t[i] >= 0x61 && t[i] <= 0x7A)) && letters < 4 {
            column = column * 26 + Int(t[i] & 0x1F)
            i += 1
            letters += 1
        }
        let hasColumn = letters > 0
        if i < t.count && t[i] == 0x24 { i += 1 }
        let start = i
        while i < t.count && t[i] >= 0x30 && t[i] <= 0x39 { i += 1 }
        let hasRow = i > start
        if i != t.count || (!hasRow && !hasColumn) || i - start > 7 || letters > 3 { return nil }
        let row = hasRow ? Int(String(decoding: t[start..<i], as: UTF16.self))! : 0
        if column > XlsxLimits.maxColumn || row > XlsxLimits.maxRow || (hasRow && row < 1) { return nil }
        return Part(column: column, row: row, hasRow: hasRow, hasColumn: hasColumn)
    }

    /// A single cell such as B12; nil if the text is anything else.
    static func cell(_ text: String?) -> (column: Int, row: Int)? {
        guard let text, let p = split(Array(text.utf16)[...]), p.hasRow, p.hasColumn else { return nil }
        return (p.column, p.row)
    }

    static func range(_ text: String?) -> XlsxRange? {
        guard let text else { return nil }
        let t = Array(text.utf16)
        let colon = t.firstIndex(of: 0x3A)
        let firstText = colon.map { t[..<$0] } ?? t[...]
        let first = split(firstText).flatMap { $0.hasRow && $0.hasColumn ? $0 : nil }
        let last = colon == nil ? first : split(t[(colon! + 1)...]).flatMap { $0.hasRow && $0.hasColumn ? $0 : nil }
        guard let a = first, let b = last else { return nil }
        return XlsxRange(firstRow: min(a.row, b.row), firstColumn: min(a.column, b.column), lastRow: max(a.row, b.row), lastColumn: max(a.column, b.column))
    }

    private static func pair(_ text: String) -> (Part, Part)? {
        let t = Array(text.utf16)
        guard let colon = t.firstIndex(of: 0x3A), let a = split(t[..<colon]), let b = split(t[(colon + 1)...]) else { return nil }
        return (a, b)
    }

    /// A column span such as $A:$C.
    static func columns(_ text: String) -> (first: Int, last: Int)? {
        guard let (a, b) = pair(text), !a.hasRow, !b.hasRow, a.hasColumn, b.hasColumn else { return nil }
        return (min(a.column, b.column), max(a.column, b.column))
    }

    /// A row span such as $1:$2.
    static func rows(_ text: String) -> (first: Int, last: Int)? {
        guard let (a, b) = pair(text), !a.hasColumn, !b.hasColumn, a.hasRow, b.hasRow else { return nil }
        return (min(a.row, b.row), max(a.row, b.row))
    }

    /// The comma separated parts of a name's formula, leaving alone commas inside a quoted sheet name.
    static func splitList(_ text: [UInt16]) -> [[UInt16]] {
        var parts: [[UInt16]] = []
        var current: [UInt16] = []
        var quoted = false
        for c in text {
            if c == 0x27 { quoted.toggle() }
            if c == 0x2C && !quoted {
                parts.append(current)
                current = []
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// What follows the sheet name and the exclamation mark.
    static func afterSheet(_ part: [UInt16]) -> String {
        var quoted = false
        var bang = -1
        for (i, c) in part.enumerated() {
            if c == 0x27 {
                quoted.toggle()
            } else if c == 0x21 && !quoted {
                bang = i
            }
        }
        return XlsxParse.trim(String(decoding: part[(bang + 1)...], as: UTF16.self))
    }
}
