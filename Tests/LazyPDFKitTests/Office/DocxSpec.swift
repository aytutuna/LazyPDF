import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Office/DocxSpec.cs: reads docx-input.txt, the cases of
// Tests/Fixtures/golden/office-docx, into packages and dumps what the reader made of them.

enum DocxSpec {
    private static let namespaces =
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" " +
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" " +
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" " +
        "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" " +
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" " +
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" " +
        "xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\" " +
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" " +
        "xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" " +
        "xmlns:v=\"urn:schemas-microsoft-com:vml\""

    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let main = "application/vnd.openxmlformats-officedocument.wordprocessingml."

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

    /// The package of a case, with the boilerplate around the parts the case wrote.
    static func package(_ parts: [(key: String, text: String)]) throws -> [UInt8] {
        func get(_ key: String) -> String { parts.first { $0.key == key }?.text ?? "" }
        var entries: [ExportZipEntry] = []
        var relationships = ""
        var types = ""

        func add(_ path: String, _ xml: String) { entries.append(ExportZipEntry(path, Array(xml.utf8))) }

        func wrapped(_ key: String, _ path: String, _ relationType: String, _ id: String, _ root: String, _ contentType: String) {
            if !parts.contains(where: { $0.key == key }) { return }
            add(path, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><\(root) \(namespaces)>\(get(key))</\(root)>")
            relationships += "<Relationship Id=\"\(id)\" Type=\"\(rel)\(relationType)\" Target=\"\(path.dropFirst(5))\"/>"
            types += "<Override PartName=\"/\(path)\" ContentType=\"\(contentType)\"/>"
        }

        add("word/document.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(namespaces)><w:body>\(get("document"))</w:body></w:document>")
        wrapped("styles", "word/styles.xml", "styles", "rIdS", "w:styles", main + "styles+xml")
        wrapped("numbering", "word/numbering.xml", "numbering", "rIdN", "w:numbering", main + "numbering+xml")
        wrapped("theme", "word/theme/theme1.xml", "theme", "rIdT", "a:theme", "application/vnd.openxmlformats-officedocument.theme+xml")
        wrapped("header", "word/header1.xml", "header", "rIdH", "w:hdr", main + "header+xml")
        wrapped("footer", "word/footer1.xml", "footer", "rIdF", "w:ftr", main + "footer+xml")
        wrapped("settings", "word/settings.xml", "settings", "rIdG", "w:settings", main + "settings+xml")
        relationships += get("relationships")
        for part in parts {
            if part.key.hasPrefix("part ") {
                add(String(part.key.dropFirst(5)), part.text)
            } else if part.key.hasPrefix("bytes ") {
                entries.append(ExportZipEntry(String(part.key.dropFirst(6)), hex(part.text)))
            }
        }
        add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Default Extension=\"png\" ContentType=\"image/png\"/>" +
            "<Override PartName=\"/word/document.xml\" ContentType=\"\(main)document.main+xml\"/>\(types)</Types>")
        add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"\(rel)officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        add("word/_rels/document.xml.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>")
        return try ExportZip.make(entries)
    }

    private static func hex(_ text: String) -> [UInt8] {
        let digits = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...($0 + 1)], as: UTF8.self), radix: 16)! }
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0)
    }

    static func dump(_ document: LayoutDocument) -> String {
        var o = ""
        for section in document.sections {
            let g = section.page
            o += "section \(num(g.width)) \(num(g.height)) \(num(g.top)) \(num(g.right)) \(num(g.bottom)) \(num(g.left)) \(num(g.headerDistance)) \(num(g.footerDistance))\n"
            if section.titlePage { o += "titlepage\n" }
            if section.evenAndOdd { o += "evenandodd\n" }
            for p in section.header { paragraph(&o, "header", p) }
            for p in section.footer { paragraph(&o, "footer", p) }
            for p in section.firstHeader { paragraph(&o, "header-first", p) }
            for p in section.firstFooter { paragraph(&o, "footer-first", p) }
            for p in section.evenHeader { paragraph(&o, "header-even", p) }
            for p in section.evenFooter { paragraph(&o, "footer-even", p) }
            for block in section.blocks {
                if let p = block as? LayoutParagraph {
                    paragraph(&o, "p", p)
                } else if let t = block as? LayoutTable {
                    table(&o, t)
                } else {
                    o += "pagebreak\n"
                }
            }
        }
        for s in document.skipped { o += "skipped \(s.kind) \(s.count)\n" }
        return o
    }

    private static func edge(_ b: LayoutBorder?) -> String {
        guard let b else { return "-" }
        return "\(num(b.width)):" + String(format: "%06x", b.color)
    }

    private static func table(_ o: inout String, _ t: LayoutTable) {
        let align: String
        switch t.align {
        case .left: align = "left"
        case .center: align = "center"
        case .right: align = "right"
        case .justify: align = "justify"
        }
        o += "table \(t.columns.map { num($0) }.joined(separator: ",")) indent=\(num(t.indent)) \(align)\n"
        for row in t.rows {
            o += "row"
            if row.header { o += " header" }
            if row.cantSplit { o += " cantsplit" }
            if row.height > 0 { o += " height=\(num(row.height))" + (row.heightExact ? " exact" : "") }
            o += "\n"
            for c in row.cells {
                let fill = c.fill.map { String(format: "%06x", $0) } ?? "-"
                let valign: String
                switch c.vAlign {
                case .top: valign = "top"
                case .center: valign = "center"
                case .bottom: valign = "bottom"
                }
                o += "cell \(c.column) \(c.span) \(c.rowSpan) fill=\(fill) margin=\(num(c.marginTop)),\(num(c.marginRight)),\(num(c.marginBottom)),\(num(c.marginLeft)) valign=\(valign)"
                o += " edges=\(edge(c.top)),\(edge(c.right)),\(edge(c.bottom)),\(edge(c.left))\n"
                for p in c.paragraphs { paragraph(&o, "cp", p) }
            }
        }
    }

    private static func paragraph(_ o: inout String, _ band: String, _ p: LayoutParagraph) {
        let align: String
        switch p.align {
        case .left: align = "left"
        case .center: align = "center"
        case .right: align = "right"
        case .justify: align = "justify"
        }
        let rule: String
        switch p.rule {
        case .multiple: rule = "multiple"
        case .exact: rule = "exact"
        case .atLeast: rule = "atleast"
        }
        o += "\(band) \(align) \(num(p.left)) \(num(p.right)) \(num(p.firstLine)) \(num(p.before)) \(num(p.after)) \(num(p.lineSpacing)) \(rule)"
        if p.keepWithNext { o += " keep" }
        if p.pageBreakBefore { o += " break" }
        if let tab = p.labelTab { o += " labeltab=\(num(tab))" }
        if !p.widowControl { o += " nowidow" }
        if p.rightToLeft { o += " rtl" }
        o += "\n"
        for r in p.runs {
            o += "  run \(r.family.replacingOccurrences(of: " ", with: "_")) \(num(r.size)) \(String(format: "%06x", r.color))"
            if r.bold { o += " b" }
            if r.italic { o += " i" }
            if r.underline { o += " u" }
            if r.strike { o += " s" }
            if r.rtl { o += " rtl" }
            if let hl = r.highlight { o += " hl=" + String(format: "%06x", hl) }
            if r.shift != 0 { o += " shift=\(num(r.shift))" }
            switch r.field {
            case .none: break
            case .pageNumber: o += " field=pagenumber"
            case .pageCount: o += " field=pagecount"
            }
            if let pic = r.picture {
                o += " picture=\(num(pic.width))x\(num(pic.height)) bytes=\(pic.file.bytes.count) crop=\(num(pic.cropLeft)),\(num(pic.cropTop)),\(num(pic.cropRight)),\(num(pic.cropBottom))"
            }
            o += " \"\(OfficeLayoutSpec.escape(r.text))\"\n"
        }
    }
}
