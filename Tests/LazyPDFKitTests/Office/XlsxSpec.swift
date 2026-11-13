import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Office/XlsxSpec.cs: reads xlsx-input.txt, the cases of
// Tests/Fixtures/golden/office-xlsx, into packages and dumps what the reader made of them.

enum XlsxSpec {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml."

    static func read(_ input: String) throws -> [(name: String, package: [UInt8])] {
        var cases: [(name: String, package: [UInt8])] = []
        var name: String?
        var parts: [(key: String, text: String)] = []

        func flush() throws {
            if let name { cases.append((name, try package(parts))) }
            parts = []
        }

        for line in input.components(separatedBy: "\n") {
            if line.hasPrefix("> ") {
                try flush()
                name = String(line.dropFirst(2))
            } else if line.hasPrefix("@") {
                parts.removeAll { $0.key == String(line.dropFirst()) }
                parts.append((String(line.dropFirst()), ""))
            } else if !parts.isEmpty && !line.hasPrefix("# ") {
                parts[parts.count - 1].text += line + "\n"
            }
        }
        try flush()
        return cases
    }

    static func package(_ parts: [(key: String, text: String)]) throws -> [UInt8] {
        func get(_ key: String) -> String { parts.first { $0.key == key }?.text ?? "" }
        var entries: [ExportZipEntry] = []
        var relationships = ""
        var types = ""

        func add(_ path: String, _ xml: String) { entries.append(ExportZipEntry(path, Array(xml.utf8))) }

        func wrapped(_ key: String, _ path: String, _ relationType: String, _ id: String, _ root: String, _ contentType: String) {
            if !parts.contains(where: { $0.key == key }) { return }
            add(path, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><\(root) xmlns=\"\(main)\" xmlns:r=\"\(rel.dropLast())\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">\(get(key))</\(root)>")
            relationships += "<Relationship Id=\"\(id)\" Type=\"\(rel)\(relationType)\" Target=\"\(path.dropFirst(3))\"/>"
            types += "<Override PartName=\"/\(path)\" ContentType=\"\(contentType)\"/>"
        }

        for part in parts where part.key.hasPrefix("sheet") {
            let n = part.key.dropFirst(5)
            wrapped(part.key, "xl/worksheets/sheet\(n).xml", "worksheet", "rId\(n)", "worksheet", sheet + "worksheet+xml")
        }
        wrapped("styles", "xl/styles.xml", "styles", "rIdS", "styleSheet", sheet + "styles+xml")
        wrapped("strings", "xl/sharedStrings.xml", "sharedStrings", "rIdSS", "sst", sheet + "sharedStrings+xml")
        wrapped("theme", "xl/theme/theme1.xml", "theme", "rIdT", "a:theme", "application/vnd.openxmlformats-officedocument.theme+xml")
        relationships += get("relationships")
        for part in parts where part.key.hasPrefix("part ") { add(String(part.key.dropFirst(5)), part.text) }
        add("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"\(main)\" xmlns:r=\"\(rel.dropLast())\">\(get("workbook"))</workbook>")
        add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"\(sheet)sheet.main+xml\"/>\(types)</Types>")
        add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"\(rel)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        add("xl/_rels/workbook.xml.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>")
        return try ExportZip.make(entries)
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0)
    }

    private static func rgb(_ color: Int?) -> String {
        guard let color else { return "-" }
        let hex = String(color, radix: 16)
        return String(repeating: "0", count: max(0, 6 - hex.count)) + hex
    }

    private static func edge(_ e: XlsxBorderEdge?) -> String { e.map { "\($0.style):\(rgb($0.color))" } ?? "-" }

    private static func name(_ column: Int) -> String {
        var letters = ""
        var c = column
        while c > 0 {
            letters = String(UnicodeScalar(UInt8(65 + (c - 1) % 26))) + letters
            c = (c - 1) / 26
        }
        return letters
    }

    private static func cells(_ r: XlsxRange) -> String { "\(name(r.firstColumn))\(r.firstRow):\(name(r.lastColumn))\(r.lastRow)" }

    private static func font(_ f: XlsxFont, _ separator: String) -> String {
        [f.name.replacingOccurrences(of: " ", with: "_"), num(f.size), rgb(f.color)].joined(separator: separator)
            + (f.bold ? separator + "b" : "") + (f.italic ? separator + "i" : "") + (f.underline ? separator + "u" : "") + (f.strike ? separator + "s" : "")
    }

    private static func setupLine(_ s: XlsxPageSetup) -> String {
        var o = "paper=\(s.paper)\(s.landscape ? " landscape" : "") scale=\(s.scale) fit=\(s.fitToWidth)x\(s.fitToHeight)\(s.fitToPage ? " fitpage" : "")"
        o += " margins=\(num(s.left)),\(num(s.right)),\(num(s.top)),\(num(s.bottom)),\(num(s.header)),\(num(s.footer))"
        o += "\(s.centerHorizontally ? " centerh" : "")\(s.centerVertically ? " centerv" : "")\(s.gridlines ? " gridlines" : "")\(s.headings ? " headings" : "")\(s.overThenDown ? " overthendown" : "")"
        o += "\(s.firstPageNumber.map { " firstpage=\($0)" } ?? "")\(s.differentOddEven ? " oddeven" : "")\(s.differentFirst ? " differentfirst" : "")\(s.scaleWithDocument ? "" : " noscale")\(s.alignWithMargins ? "" : " noalign")"
        return o
    }

    private static func dumpSetup(_ s: XlsxPageSetup) -> String {
        var o = ""
        if setupLine(s) != setupLine(XlsxPageSetup()) { o += "  setup \(setupLine(s))\n" }
        for (name, text) in [("oddheader", s.oddHeader), ("oddfooter", s.oddFooter), ("evenheader", s.evenHeader), ("evenfooter", s.evenFooter), ("firstheader", s.firstHeader), ("firstfooter", s.firstFooter)]
        where !text.isEmpty {
            o += "  \(name) \"\(OfficeLayoutSpec.escape(text))\"\n"
        }
        if !s.rowBreaks.isEmpty { o += "  rowbreaks \(s.rowBreaks.map(String.init).joined(separator: ","))\n" }
        if !s.columnBreaks.isEmpty { o += "  colbreaks \(s.columnBreaks.map(String.init).joined(separator: ","))\n" }
        return o
    }

    static func dump(_ workbook: XlsxWorkbook) -> String {
        var o = ""
        let styles = workbook.styles
        o += "workbook\(workbook.date1904 ? " date1904" : "") mdw=\(styles.maxDigitWidth)\n"
        if styles.xfs.count > 1 || styles.fonts.count > 1 {
            for (i, f) in styles.fonts.enumerated() { o += "font \(i) \(font(f, " "))\n" }
            for (i, f) in styles.fills.enumerated() { o += "fill \(i) \(rgb(f.color))\(f.unsupported ? " unsupported" : "")\n" }
            for (i, b) in styles.borders.enumerated() { o += "border \(i) \(edge(b.left)) \(edge(b.right)) \(edge(b.top)) \(edge(b.bottom))\n" }
            for (i, x) in styles.xfs.enumerated() {
                o += "xf \(i) font=\(x.font) fill=\(x.fill) border=\(x.border) fmt=\(x.numberFormatId) \(x.horizontal.rawValue.lowercased()) \(x.vertical.rawValue.lowercased()) indent=\(x.indent)\(x.wrap ? " wrap" : "")\(x.rotated ? " rotated" : "")\(x.readingOrder != 0 ? " order=\(x.readingOrder)" : "")\n"
            }
        }
        for sheet in workbook.sheets {
            o += "sheet \"\(OfficeLayoutSpec.escape(sheet.name))\" col=\(num(sheet.defaultColumnWidth)) row=\(num(sheet.defaultRowHeight))\(sheet.rightToLeft ? " rtl" : "")\n"
            for c in sheet.columns { o += "  cols \(c.first)-\(c.last) \(num(c.width))\(c.hidden ? " hidden" : "")\n" }
            for row in sheet.rows {
                o += "  row \(row.index)\(row.height.map { " h=" + num($0) } ?? "")\(row.hidden ? " hidden" : "")\n"
                for c in row.cells {
                    let kind: String
                    switch c.kind {
                    case .number: kind = "n"
                    case .text: kind = "t"
                    case .bool: kind = "b"
                    case .error: kind = "e"
                    case .blank: kind = "-"
                    }
                    o += "    \(name(c.column))\(row.index) \(kind) s=\(c.style) \"\(OfficeLayoutSpec.escape(c.text))\""
                    if let color = c.color { o += " color=\(rgb(color))" }
                    if let f = c.richFont { o += " rich=\(font(f, ","))" }
                    o += "\n"
                }
            }
            for m in sheet.merges { o += "  merge \(cells(m))\n" }
            if !sheet.printArea.isEmpty { o += "  printarea \(sheet.printArea.map(cells).joined(separator: ","))\n" }
            if let t = sheet.titleRows { o += "  titlerows \(t.first):\(t.last)\n" }
            if let t = sheet.titleColumns { o += "  titlecols \(name(t.first)):\(name(t.last))\n" }
            o += dumpSetup(sheet.setup)
        }
        for s in workbook.skipped { o += "skipped \(s.kind) \(s.count)\n" }
        return o
    }
}
