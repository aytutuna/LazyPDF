import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Office/PptxSpec.cs: reads pptx-input.txt, the cases of
// Tests/Fixtures/golden/office-pptx, into packages. The format is described there.

enum PptxSpec {
    private static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let rel = r + "/"
    private static let ml = "application/vnd.openxmlformats-officedocument.presentationml."

    private static let standardPresentation =
        "<p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:defaultTextStyle><a:lvl1pPr marL=\"0\"><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr>" +
        "<a:lvl2pPr marL=\"457200\"><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl2pPr></p:defaultTextStyle>"

    private static let standardTheme =
        "<a:themeElements><a:clrScheme name=\"Office\"><a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>" +
        "<a:dk2><a:srgbClr val=\"1F497D\"/></a:dk2><a:lt2><a:srgbClr val=\"EEECE1\"/></a:lt2><a:accent1><a:srgbClr val=\"4F81BD\"/></a:accent1><a:accent2><a:srgbClr val=\"C0504D\"/></a:accent2>" +
        "<a:accent3><a:srgbClr val=\"9BBB59\"/></a:accent3><a:accent4><a:srgbClr val=\"8064A2\"/></a:accent4><a:accent5><a:srgbClr val=\"4BACC6\"/></a:accent5><a:accent6><a:srgbClr val=\"F79646\"/></a:accent6>" +
        "<a:hlink><a:srgbClr val=\"0000FF\"/></a:hlink><a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink></a:clrScheme>" +
        "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Cambria\"/></a:majorFont><a:minorFont><a:latin typeface=\"Calibri\"/></a:minorFont></a:fontScheme>" +
        "<a:fmtScheme name=\"Office\"><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"50000\"/></a:schemeClr></a:solidFill>" +
        "<a:gradFill><a:gsLst><a:gs pos=\"0\"><a:schemeClr val=\"phClr\"><a:shade val=\"50000\"/></a:schemeClr></a:gs><a:gs pos=\"100000\"><a:schemeClr val=\"phClr\"/></a:gs></a:gsLst></a:gradFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements>"

    private final class Part {
        let kind: String
        var arguments: [(key: String, value: String)] = []
        var text = ""

        init(_ words: [String]) {
            kind = words[0]
            for word in words.dropFirst() {
                let pieces = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                arguments.append((String(pieces[0]), pieces.count > 1 ? String(pieces[1]) : ""))
            }
        }

        func argument(_ key: String, _ fallback: String) -> String { arguments.first { $0.key == key }?.value ?? fallback }
    }

    static func read(_ input: String) throws -> [(name: String, package: [UInt8])] {
        var cases: [(name: String, package: [UInt8])] = []
        var name: String?
        var parts: [Part] = []

        func flush() throws {
            if let name { cases.append((name, try package(parts))) }
            parts = []
        }

        for line in input.components(separatedBy: "\n") {
            if line.hasPrefix("> ") {
                try flush()
                name = String(line.dropFirst(2))
            } else if line.hasPrefix("@") {
                parts.append(Part(line.dropFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)))
            } else if let last = parts.last, !line.hasPrefix("# ") {
                last.text += line + "\n"
            }
        }
        try flush()
        return cases
    }

    /// The package of a single case written in the format above, without the line that starts it.
    static func one(_ text: String) throws -> [UInt8] { try read("> case\n" + text)[0].package }

    private static func package(_ parts: [Part]) throws -> [UInt8] {
        var entries: [ExportZipEntry] = []
        var types = ""
        var extra: [String: String] = [:]
        for part in parts where part.kind == "rels" { extra[part.arguments[0].key] = part.text }

        func add(_ path: String, _ xml: String) { entries.append(ExportZipEntry(path, Array(xml.utf8))) }

        func wrapped(_ root: String, _ attributes: String, _ inside: String) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><\(root) xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"\(attributes)>\(inside)</\(root)>"
        }

        func attributes(_ part: Part) -> String {
            part.arguments.filter { $0.key != "layout" && $0.key != "master" && $0.key != "theme" }.map { " \($0.key)=\"\($0.value)\"" }.joined()
        }

        func rels(_ path: String, _ key: String, _ list: String) {
            let slash = path.lastIndex(of: "/")!
            let folder = String(path[..<slash]), file = String(path[path.index(after: slash)...])
            add("\(folder)/_rels/\(file).rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(list)\(extra[key] ?? "")</Relationships>")
        }

        func number(_ part: Part, _ prefix: Int) -> Int { Int(part.kind.dropFirst(prefix))! }
        let slides = parts.enumerated().filter { $0.element.kind.hasPrefix("slide") }
            .sorted { (number($0.element, 5), $0.offset) < (number($1.element, 5), $1.offset) }.map { $0.element }
        var layouts = parts.filter { $0.kind.hasPrefix("layout") }
        var masters = parts.filter { $0.kind.hasPrefix("master") }
        if !layouts.contains(where: { $0.kind == "layout1" }) { layouts.append(Part(["layout1"])) }
        if !masters.contains(where: { $0.kind == "master1" }) { masters.append(Part(["master1"])) }
        let theme = parts.first { $0.kind == "theme" }
        let presentation = parts.first { $0.kind == "presentation" }

        var ids = ""
        var presentationRels = ""
        for (i, slide) in slides.enumerated() {
            let n = String(slide.kind.dropFirst(5))
            ids += "<p:sldId id=\"\(256 + i)\" r:id=\"rIdS\(n)\"/>"
            presentationRels += "<Relationship Id=\"rIdS\(n)\" Type=\"\(rel)slide\" Target=\"slides/slide\(n).xml\"/>"
            add("ppt/slides/slide\(n).xml", wrapped("p:sld", attributes(slide), slide.text))
            rels("ppt/slides/slide\(n).xml", slide.kind, "<Relationship Id=\"rIdL\" Type=\"\(rel)slideLayout\" Target=\"../slideLayouts/slideLayout\(slide.argument("layout", "1")).xml\"/>")
            types += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"\(ml)slide+xml\"/>"
        }
        for layout in layouts {
            let n = String(layout.kind.dropFirst(6))
            add("ppt/slideLayouts/slideLayout\(n).xml", wrapped("p:sldLayout", attributes(layout), layout.text.isEmpty ? "<p:cSld><p:spTree/></p:cSld>" : layout.text))
            rels("ppt/slideLayouts/slideLayout\(n).xml", layout.kind, "<Relationship Id=\"rIdM\" Type=\"\(rel)slideMaster\" Target=\"../slideMasters/slideMaster\(layout.argument("master", "1")).xml\"/>")
            types += "<Override PartName=\"/ppt/slideLayouts/slideLayout\(n).xml\" ContentType=\"\(ml)slideLayout+xml\"/>"
        }
        for master in masters {
            let n = String(master.kind.dropFirst(6))
            add("ppt/slideMasters/slideMaster\(n).xml", wrapped("p:sldMaster", attributes(master), master.text.isEmpty ? "<p:cSld><p:spTree/></p:cSld>" : master.text))
            rels("ppt/slideMasters/slideMaster\(n).xml", master.kind, "<Relationship Id=\"rIdT\" Type=\"\(rel)theme\" Target=\"../theme/theme1.xml\"/>")
            types += "<Override PartName=\"/ppt/slideMasters/slideMaster\(n).xml\" ContentType=\"\(ml)slideMaster+xml\"/>"
        }
        let themeText = theme.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        add("ppt/theme/theme1.xml", wrapped("a:theme", "", themeText == nil || themeText!.isEmpty ? standardTheme : theme!.text))
        types += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for part in parts where part.kind == "part" {
            var text = part.text
            while text.hasSuffix("\n") { text.removeLast() }
            add(part.arguments[0].key, text)
        }
        for part in parts where part.kind == "bytes" {
            let digits = Array(part.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            let bytes = stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)! }
            entries.append(ExportZipEntry(part.arguments[0].key, bytes))
        }

        let presentationText = presentation.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        add("ppt/presentation.xml", wrapped("p:presentation", presentation.map(attributes) ?? "",
            "<p:sldIdLst>\(ids)</p:sldIdLst>" + (presentationText == nil || presentationText!.isEmpty ? standardPresentation : presentation!.text)))
        rels("ppt/presentation.xml", "presentation", presentationRels)
        add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(ml)presentation.main+xml\"/>\(types)</Types>")
        add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"\(rel)officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        return try ExportZip.make(entries)
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0)
    }

    private static func styleName(_ style: FontStyles) -> String {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return "Bold, Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        default: return "Regular"
        }
    }

    static func dump(_ layout: LayoutResult) -> String {
        var output = ""
        for (i, page) in layout.pages.enumerated() {
            output += "page \(i + 1) \(num(page.width)) \(num(page.height))\n"
            for box in page.boxes {
                switch box {
                case .text(let t):
                    output += "text \(num(t.x)) \(num(t.baseline)) \(t.family)/\(styleName(t.style)) \(num(t.size)) \(String(format: "%06x", t.color)) +\(num(t.spaceExtra)) \"\(OfficeLayoutSpec.escape(t.text))\"\n"
                case .rect(let r):
                    output += "rect \(num(r.x)) \(num(r.y)) \(num(r.width)) \(num(r.height)) \(String(format: "%06x", r.color))\n"
                case .image(let m):
                    output += "image \(num(m.x)) \(num(m.y)) \(num(m.width)) \(num(m.height)) \(m.source.file.bytes.count) crop \(num(m.source.cropLeft)) \(num(m.source.cropTop)) \(num(m.source.cropRight)) \(num(m.source.cropBottom))\(m.rotation != 0 ? " rot \(num(m.rotation))" : "")\(m.flipH ? " flip" : "")\n"
                case .path(let p):
                    let fill = p.fill.map { String(format: "%06x", $0) } ?? "-"
                    let stroke = p.stroke.map { "\(num($0.width)) \(String(format: "%06x", $0.color)) \($0.dash.isEmpty ? "-" : $0.dash.map(num).joined(separator: ","))" } ?? "-"
                    output += "path \(fill) \(stroke)"
                    for c in p.commands {
                        switch c {
                        case .move(let x, let y): output += " M \(num(x)) \(num(y))"
                        case .line(let x, let y): output += " L \(num(x)) \(num(y))"
                        case .curve(let x1, let y1, let x2, let y2, let x, let y): output += " C \(num(x1)) \(num(y1)) \(num(x2)) \(num(y2)) \(num(x)) \(num(y))"
                        case .close: output += " Z"
                        }
                    }
                    output += "\n"
                }
            }
        }
        for s in layout.skipped { output += "skipped \(s.kind) \(s.count)\n" }
        return output
    }
}
