import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Structure/StructureGolden.cs. One line of input is "<op> <words>" (the format is at
// the top of structure-input.txt): text strings and dates, XMP packets rewritten by the metadata writer, actions and
// destinations read from small objects, and fixed scenarios whose objects are printed. Numbers go through PdfNumber,
// which both sides write alike. Line ends in a rewritten XMP packet are LF: XmlWriter ends a line with
// Environment.NewLine, which is CRLF on Windows, and the writer here always uses LF.
enum StructureGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            output += "> \(line)\n"
            for result in try self.op(op, rest) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        do {
            switch op {
            case "text": return [show(PdfText.decode(Golden.unescape(rest)))]
            case "encode": return [hex(PdfText.encode(utf8(rest)))]
            case "object": return [PdfText.toObject(utf8(rest)).description]
            case "key": return [show(PdfNameTree.keyOf(utf8(rest))), show(PdfNameTree.textOf(PdfNameTree.keyOf(utf8(rest))))]
            case "date": return [date(rest)]
            case "xmpdate": return [xmpDate(rest)]
            case "labels": return try labels(rest)
            case "meta": return try meta(rest)
            case "action": return try action(rest)
            case "dest": return try dest(rest, false)
            case "destr": return try dest(rest, true)
            case "scenario": return try scenario(rest)
            default: return ["unknown op \(op)"]
            }
        } catch let failure as PdfReadException {
            return ["error \(problemName(failure.problem)) \(failure.message)"]
        }
    }

    private static func problemName(_ problem: PdfReadProblem) -> String {
        switch problem {
        case .notPdf: return "NotPdf"
        case .damaged: return "Damaged"
        case .encrypted: return "Encrypted"
        case .passwordRequired: return "PasswordRequired"
        case .unsupported: return "Unsupported"
        case .certificateRequired: return "CertificateRequired"
        }
    }

    private static func utf8(_ rest: String) -> String { String(decoding: Golden.unescape(rest), as: UTF8.self) }

    private static func latin(_ rest: String) -> String { Latin1.string(Golden.unescape(rest)) }

    // A string with every character outside printable ASCII as \uXXXX of its UTF-16 unit.
    private static func show(_ text: String) -> String {
        var result = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            default:
                if unit < 0x20 || unit >= 0x7F {
                    result += "\\u" + String(format: "%04lx", Int(unit))
                } else {
                    result.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                }
            }
        }
        return result
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", Int($0)) }.joined() }

    private static func date(_ rest: String) -> String {
        guard let d = PdfDate.parse(latin(rest)) else { return "null" }
        return "\(d) \(PdfDate.format(d)) \(PdfDate.formatXmp(d))"
    }

    private static func xmpDate(_ rest: String) -> String {
        PdfDate.parseXmp(latin(rest)).map { "\($0)" } ?? "null"
    }

    private static func n(_ value: Double?) -> String { value.map { PdfNumber($0).description } ?? "-" }

    private static func b(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "-" }

    private static let fitNames = ["Xyz", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV"]

    private static func d(_ d: PdfDestination?) -> String {
        guard let d else { return "-" }
        let name = d.name.map { show($0) } ?? "-"
        return "page=\(d.pageIndex) fit=\(fitNames[d.fit.rawValue]) left=\(n(d.left)) bottom=\(n(d.bottom)) right=\(n(d.right)) top=\(n(d.top)) zoom=\(n(d.zoom)) name=\(name)"
    }

    private static func dump(_ document: PdfDocument, from: Int = 1) -> String {
        var lines: [String] = []
        for number in document.objectNumbers where number >= from {
            let value = document.get(number)
            lines.append("\(number): " + (value is PdfStream ? "stream" : (value?.description ?? "null")))
        }
        return lines.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // start:style:prefix:first;... | pages. The labels of the pages, then the objects a write of the ranges makes.
    private static func labels(_ rest: String) throws -> [String] {
        let parts = rest.components(separatedBy: " | ")
        let ranges: [PageLabelRange] = parts[0].components(separatedBy: ";").map { r in
            let f = r.components(separatedBy: ":")
            let style: PageLabelStyle
            switch f[1] {
            case "D": style = .decimal
            case "R": style = .upperRoman
            case "r": style = .lowerRoman
            case "A": style = .upperLetters
            case "a": style = .lowerLetters
            default: style = .none
            }
            // int.Parse takes the spaces around a number.
            return PageLabelRange(Int(f[0].trimmingCharacters(in: .whitespaces)) ?? 0, style, f[2], Int(f[3].trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        let pages = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let document = try StructureFixtures.open(2)
        try PdfPageLabels.write(document, ranges)
        return [(0..<pages).map { show(PdfPageLabels.label(ranges, $0)) }.joined(separator: ",")] + lines(dump(document))
    }

    // Writes a fixed record into a file whose /Metadata is the bytes, and shows /Info and what became of the packet.
    private static func meta(_ rest: String) throws -> [String] {
        let bytes = Golden.unescape(rest)
        let document = try StructureFixtures.file("/Metadata 30 0 R", { pdf in pdf.stream(30, "/Type /Metadata /Subtype /XML", bytes) }, pages: 1)
        var custom = OrderedStrings()
        custom["Department"] = "Finance"
        custom["bad key"] = "x"
        custom["Note"] = "T\u{FC}rk\u{E7}e"
        custom["Empty"] = ""
        custom["Ctl"] = "a\u{1}b\r\nc"
        try DocumentMetadata(
            "Golden title", "A. Writer", "Subject & more <x>", "one, two;three,, ;four", "Tool", "Lazy PDF",
            DateTimeOffset(2026, 1, 2, 3, 4, 5, offsetMinutes: 180), DateTimeOffset(2026, 2, 3, 4, 5, 6, offsetMinutes: -300),
            custom).write(document)
        let stream = try XCTUnwrap(document.stream(document.catalog, "Metadata"))
        let packet = String(decoding: try document.data(stream), as: UTF8.self)
        let read = DocumentMetadata.read(document)
        let fields = [read.title, read.author, read.subject, read.keywords].map { show($0 ?? "-") }.joined(separator: "|")
        let created = read.created.map { "\($0)" } ?? "-"
        let modified = read.modified.map { "\($0)" } ?? "-"
        let extras = read.custom.entries.map { $0.key + "=" + show($0.value) }.joined(separator: ",")
        return [
            "info " + (document.info?.description ?? ""),
            "xmp " + show(packet),
            "read \(fields)|\(created)|\(modified)|\(extras)",
        ]
    }

    private static func describe(_ action: PdfAction) -> String {
        let text: String
        switch action {
        case let a as GoToAction: text = "GoTo " + d(a.destination)
        case let a as GoToRemoteAction: text = "GoToR file=\(show(a.file)) new=\(b(a.newWindow)) dest=\(d(a.destination))"
        case let a as LaunchAction: text = "Launch file=\(a.file.map { show($0) } ?? "-") new=\(b(a.newWindow))"
        case let a as UriAction: text = "Uri " + show(a.uri)
        case let a as NamedAction: text = "Named " + show(a.name)
        case let a as JavaScriptAction: text = "JavaScript " + show(a.script)
        case let a as SubmitFormAction: text = "SubmitForm url=\(show(a.url)) flags=\(a.flags) fields=[\(a.fields.map { show($0) }.joined(separator: "|"))]"
        case let a as ResetFormAction: text = "ResetForm flags=\(a.flags) fields=[\(a.fields.map { show($0) }.joined(separator: "|"))]"
        case let a as OtherAction: text = "Other " + show(a.type)
        default: text = "?"
        }
        return text + " next=[" + action.next.map { describe($0) }.joined(separator: ", ") + "]"
    }

    // <object 20> ;; <n>=<object> ;; <n>=stream(<bytes>) ...: the action in object 20, as read and as written again.
    private static func action(_ rest: String) throws -> [String] {
        let parts = rest.components(separatedBy: " ;; ")
        let document = try StructureFixtures.file("/OpenAction 20 0 R", { pdf in
            pdf.obj(20, parts[0])
            for extra in parts.dropFirst() {
                guard let eq = extra.firstIndex(of: "="), let number = Int(extra[..<eq]) else { continue }
                let body = String(extra[extra.index(after: eq)...])
                if body.hasPrefix("stream(") {
                    pdf.stream(number, "", Golden.unescape(String(body.dropFirst(7).dropLast())))
                } else {
                    pdf.obj(number, body)
                }
            }
        })
        guard let action = PdfActions.read(document, PdfReference(20, 0)) else { return ["null"] }
        var results = [describe(action)]
        results.append("written " + written(document, action))
        results.append("javascript " + (PdfActions.hasJavaScript(document) ? "yes" : "no"))
        return results
    }

    // ToObject refuses an action it cannot write, and a GoTo to a page that is not there.
    private static func written(_ document: PdfDocument, _ action: PdfAction) -> String {
        do {
            return try PdfActions.toObject(document, action).description
        } catch {
            return "refused"
        }
    }

    // <object 20>: the destination in it, as written again and where it lands.
    private static func dest(_ rest: String, _ remote: Bool) throws -> [String] {
        let document = try StructureFixtures.file("", { pdf in pdf.obj(20, rest) })
        guard let destination = PdfDestinations.parse(document, PdfReference(20, 0), remote: remote) else { return ["null"] }
        var results = [d(destination), "written " + (PdfDestinations.toObject(document, destination, remote: remote)?.description ?? "null")]
        if !remote {
            if let p = PdfDestinations.locate(document, destination) {
                results.append("located \(p.pageIndex) \(n(p.x)) \(n(p.y)) \(n(p.zoom))")
            } else {
                results.append("located null")
            }
        }
        return results
    }

    private static func scenario(_ name: String) throws -> [String] {
        switch name {
        case "nametree":
            let document = try StructureFixtures.open(1)
            let entries: [(key: String, value: PdfObject)] = (0..<150).reversed().map { (key: String(format: "n%03ld", $0), value: PdfNumber($0) as PdfObject) }
            let root = try PdfNameTree.write(document, nil, entries)
            PdfNames.ensure(document)["Dests"] = try document.add(root)
            return lines(dump(document))
        case "numbertree":
            let document = try StructureFixtures.open(1)
            let entries: [(key: Int, value: PdfObject)] = (0..<150).map { (key: $0 * 3, value: PdfNumber($0) as PdfObject) }
            let root = try PdfNumberTree.write(document, nil, entries)
            PdfNames.ensure(document)["Nums"] = try document.add(root)
            return lines(dump(document))
        case "actions": return try actions()
        case "destinations":
            let document = try StructureFixtures.open(3)
            let old = PdfDictionary()
            old["old"] = PdfArray([document.pages[0].reference, PdfName("Fit")])
            document.catalog["Dests"] = old
            for i in 0..<70 { try PdfDestinations.setNamed(document, String(format: "d%03ld", i), PdfDestination(i % 3, .fitH, top: Double(i))) }
            try PdfDestinations.setNamed(document, "old", PdfDestination(2))
            _ = try PdfDestinations.removeNamed(document, "d005")
            let named = PdfDestinations.named(document)
            guard let first = named.first, let last = named.last else { return ["empty"] }
            return ["\(named.count) \(first.key) \(d(first.value)) \(last.key) \(d(last.value))"] + lines(dump(document))
        case "outline": return try outlineScenario()
        case "links": return try linksScenario()
        case "viewer": return try viewerScenario()
        default: return ["unknown scenario \(name)"]
        }
    }

    private static func named(_ name: String, _ next: [PdfAction]) -> NamedAction {
        let action = NamedAction(name)
        action.next = next
        return action
    }

    private static func actions() throws -> [String] {
        let document = try StructureFixtures.open(3)
        let actions: [PdfAction] = [
            GoToAction(PdfDestination(2, .fitH, top: 7)),
            GoToAction(PdfDestination(1, .fitR, left: 1, bottom: 2, right: 3, top: 4)),
            GoToRemoteAction("o.pdf", PdfDestination(3), true),
            GoToRemoteAction("o\u{E9}.pdf", PdfDestination(-1, name: "chap"), nil),
            LaunchAction("x.exe", nil),
            LaunchAction(nil, false),
            UriAction("https://example.com/\u{E9}?a=1&b=(2)"),
            NamedAction("PrevPage"),
            JavaScriptAction("var s = \"\u{E9}\";\n\\"),
            JavaScriptAction("\u{416}"),
            SubmitFormAction("http://x/post", 4, ["a", "b\u{416}"]),
            ResetFormAction(0, []),
            ResetFormAction(1, ["f"]),
            named("A", [UriAction("u"), named("B", [NamedAction("C")])]),
            named("Only", [NamedAction("One")]),
        ]
        return try actions.map { try PdfActions.toObject(document, $0).description }
    }

    private static func outlineScenario() throws -> [String] {
        let document = try StructureFixtures.file("/Outlines 20 0 R /Names <</Dests <</Names [(target) [4 0 R /Fit]]>>>>", { pdf in
            pdf.obj(20, "<</Type /Outlines /First 21 0 R /Last 23 0 R /Count 99>>")
            pdf.obj(21, "<</Title (Chapter 1) /Parent 20 0 R /Next 22 0 R /First 24 0 R /Last 25 0 R /Count 7 /Dest [3 0 R /XYZ 0 300 null] /C [1 0 0] /F 3 /Unknown (kept)>>")
            pdf.obj(22, "<</Title (Chapter 2) /Parent 20 0 R /Prev 21 0 R /Next 23 0 R /First 26 0 R /Last 26 0 R /Count -1 /Dest (target) /SE 21 0 R>>")
            pdf.obj(23, "<</Title (Chapter 3) /Parent 20 0 R /Prev 22 0 R /Dest [5 0 R /Fit]>>")
            pdf.obj(24, "<</Title (Section 1.1) /Parent 21 0 R /Next 25 0 R /A <</S /URI /URI (http://example.com)>>>>")
            pdf.obj(25, "<</Title <FEFF04160410> /Parent 21 0 R /Prev 24 0 R /A <</S /GoTo /D [5 0 R /FitH 10]>>>>")
            pdf.obj(26, "<</Title (Appendix \\(a\\)) /Parent 22 0 R>>")
        })
        let outline = Outline.read(document)
        var read = [titles(outline.root)]
        try outline.move(outline.items[2], outline.items[0], 0)
        let turkish = OutlineItem()
        turkish.title = "T\u{FC}rk\u{E7}e"
        turkish.destination = StructureFixtures.toPage(1)
        turkish.bold = true
        turkish.color = (0, 0.5, 1)
        turkish.isOpen = true
        try outline.add(turkish)
        let link = OutlineItem()
        link.title = "Link"
        link.action = UriAction("http://x")
        try outline.add(link, outline.items.last)
        outline.items[1].title = "Renamed"
        outline.items[0].children[2].destination = nil
        outline.remove(outline.items[0].children[1])
        try outline.write(document)
        read.append(titles(outline.root))
        read.append(contentsOf: lines(dump(document, from: 20)))
        return read
    }

    private static func titles(_ item: OutlineItem) -> String {
        item.children.map { show($0.title) + ($0.children.isEmpty ? "" : "(" + titles($0) + ")") }.joined(separator: ",")
    }

    private static func linksScenario() throws -> [String] {
        let document = try StructureFixtures.open(3)
        let page = document.pages[0]
        try PdfLinks.add(document, page, PdfRect(10, 10, 60, 30), PdfDestination(2, .fitH, top: 5))
        try PdfLinks.addUri(document, page, PdfRect(70, 10, 120, 30), "https://example.com/\u{E9}")
        let removed = try PdfLinks.add(document, page, PdfRect(1, 1, 2, 2), NamedAction("NextPage"))
        try PdfLinks.add(document, document.pages[1], PdfRect(5.5, 6.25, 7, 8), GoToRemoteAction("o.pdf", PdfDestination(0), nil))
        _ = PdfLinks.remove(document, page, removed)
        var results = [dump(document, from: 3)]
        for link in PdfLinks.read(document, page) {
            let action = link.action.map { describe($0) } ?? "-"
            results.append("link \(link.rect.toArray()) \(d(link.destination)) \(action) \(link.uri ?? "-") \(link.reference?.description ?? "")")
        }
        return results.flatMap { lines($0) }
    }

    private static func viewerScenario() throws -> [String] {
        var results: [String] = []
        let document = try StructureFixtures.open(1)
        ViewerSettings("en-US", true, .fullScreen, .twoPageRight, true, true, true, true, true, true, true, "DuplexFlipShortEdge", 3).write(document)
        results.append(document.catalog.description)
        ViewerSettings(nil, false, .useNone, .singlePage, false, false, false, false, false, false, false, nil, nil).write(document)
        results.append(document.catalog.description)
        ViewerSettings("\u{416}", false, .useThumbs, .oneColumn, false, false, false, false, true, false, false, "Simplex", 9).write(document)
        results.append(document.catalog.description)
        return results
    }
}
