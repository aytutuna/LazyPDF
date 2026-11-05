import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Annotations/AnnotationsGolden.cs. One line of input is "<op> <words>" (the format is
// at the top of annotations-input.txt): appearance streams drawn for each kind, edits, the words of /DA and CSS, rich text,
// comment lists, flattening, FDF and XFDF read and written, attachments, layers and document facts. Streams are shown
// decoded, because the deflate of the two sides is not the same one; the random /NM of a new annotation is made "nm" first;
// line ends in XFDF are LF, because XmlWriter ends a line with Environment.NewLine. A bool is written the way .NET does.
enum AnnotationsGolden {
    private static let day = DateTimeOffset(2026, 3, 4, 10, 0, 0)
    private static let info = AnnotationInfo(author: "Ayşe", contents: "check this", subject: "Review", date: day)

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
            case "rich": return [show(PdfRichText.toPlain(utf8(rest)))]
            case "da": return daOp(latin(rest))
            case "css": return formatLines(TextFormat.default.withCss(utf8(rest)))
            case "ap": return try ap(rest)
            case "edit": return try edit()
            case "comments": return try comments()
            case "flatten": return try flatten(rest)
            case "fdf": return try fdf(Golden.unescape(rest))
            case "export": return try export()
            case "xfdf": return try xfdf(Golden.unescape(rest))
            case "attach": return try attach()
            case "layers": return try layers()
            case "facts": return try facts(rest)
            default: return ["unknown op \(op)"]
            }
        } catch let failure as PdfReadException {
            let message = failure.message.hasPrefix("The XFDF is not well-formed") ? "The XFDF is not well-formed" : failure.message
            return ["error \(problemName(failure.problem)) \(show(message))"]
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

    private static func n(_ value: Double?) -> String { value.map { PdfNumber($0).description } ?? "-" }

    private static func numbers(_ values: [Double]?) -> String {
        guard let values else { return "-" }
        return "[" + values.map { n($0) }.joined(separator: ",") + "]"
    }

    private static func iso(_ date: DateTimeOffset?) -> String { date.map { $0.description } ?? "-" }

    private static func b(_ value: Bool) -> String { value ? "True" : "False" }

    private static func count(_ value: Int?) -> String { value.map { String($0) } ?? "" }

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    private static func showLines(_ text: String) -> [String] { lines(text).map { show($0) } }

    private static func dump(_ document: PdfDocument, from: Int = 1) throws -> String {
        var result: [String] = []
        for number in document.objectNumbers where number >= from {
            let text: String
            switch document.get(number) {
            case let s as PdfStream: text = "stream \(s.dictionary) | \(show(Latin1.string(try document.data(s))))"
            case let d as PdfDictionary: text = fold(d)
            case let value?: text = value.description
            case nil: text = "null"
            }
            result.append("\(number): \(text)")
        }
        return result.joined(separator: "\n")
    }

    // A dictionary as text; a rich text read from XFDF has the line ends of the machine in it, so they become LF first.
    private static func fold(_ d: PdfDictionary) -> String {
        let copy = d.copy()
        if let rich = copy["RC"] as? PdfString {
            copy["RC"] = PdfText.toObject(PdfText.decode(rich.bytes).replacingOccurrences(of: "\r\n", with: "\n"))
        }
        return copy.description
    }

    // The random /NM of annotations the writer made becomes "nm", so that the dump can be compared.
    private static func fix(_ document: PdfDocument) {
        for number in document.objectNumbers {
            if let d = document.get(number) as? PdfDictionary, d.containsKey("NM"), d.containsKey("Subtype") { d["NM"] = PdfText.toObject("nm") }
        }
    }

    private static func formatLine(_ f: TextFormat) -> String {
        "format \(show(f.family))|\(n(f.size))|\(b(f.bold))|\(b(f.italic))|\(b(f.underline))|\(numbers(f.color))"
    }

    private static func formatLines(_ f: TextFormat) -> [String] {
        [formatLine(f), "build " + show(DefaultAppearance.build(f)), "style " + show(DefaultAppearance.buildStyle(f, 1))]
    }

    private static func daOp(_ da: String) -> [String] {
        let parsed = DefaultAppearance.parse(da)
        var f = TextFormat.default
        if let font = parsed.font { f = DefaultAppearance.formatOf(font, f) }
        if let size = parsed.size, size > 0 { f.size = size }
        if let color = parsed.color { f.color = color }
        let standard = parsed.font.map { DefaultAppearance.isStandard($0) } ?? false
        return ["parsed \(parsed.font.map { show($0) } ?? "-") \(n(parsed.size)) \(numbers(parsed.color)) standard=\(b(standard))"] + formatLines(f)
    }

    private static func ap(_ name: String) throws -> [String] {
        let document = try AnnotationFixtures.blank(1)
        let writer = PdfAnnotationWriter(document)
        let page = document.pages[0]
        let quads = [MarkupQuad.fromRect(PdfRect(100, 500, 300, 514)), MarkupQuad.fromRect(PdfRect(100, 480, 200, 494))]
        let points: [PdfPoint] = [(100, 600), (150, 650), (200, 600), (250, 650)]
        switch name {
        case "highlight": try writer.addTextMarkup(page, .highlight, quads, info: info, style: AnnotationStyle(opacity: 0.5))
        case "underline": try writer.addTextMarkup(page, .underline, quads, info: info, style: AnnotationStyle(color: [0, 0.5, 1]))
        case "strikeout": try writer.addTextMarkup(page, .strikeOut, quads, info: info)
        case "squiggly": try writer.addTextMarkup(page, .squiggly, quads, info: info)
        case "square": try writer.addSquare(page, PdfRect(100, 600, 200, 650), style: AnnotationStyle(color: [0, 0, 1], width: 4, fill: [1, 1, 0]), info: info)
        case "square-dash": try writer.addSquare(page, PdfRect(100, 600, 200, 650), style: AnnotationStyle(dash: [4, 2], opacity: 0.5))
        case "square-cloud": try writer.addSquare(page, PdfRect(100, 600, 260, 700), style: AnnotationStyle(cloud: 2))
        case "circle": try writer.addCircle(page, PdfRect(100, 600, 160, 660), style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [0, 1, 0]))
        case "circle-cloud": try writer.addCircle(page, PdfRect(100, 600, 260, 700), style: AnnotationStyle(cloud: 1))
        case "line": try writer.addLine(page, (100, 600), (300, 650), style: AnnotationStyle(width: 2), info: info)
        case "endings":
            for ending in [LineEnding.square, .circle, .diamond, .openArrow, .closedArrow, .butt, .rOpenArrow, .rClosedArrow, .slash] {
                try writer.addLine(page, (100, 600), (300, 650), style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [0, 1, 0]), info: nil, start: ending, end: ending)
            }
        case "arrow": try writer.addArrow(page, (100, 600), (300, 600), style: AnnotationStyle(width: 2))
        case "polyline": try writer.addPolyLine(page, points, style: AnnotationStyle(color: [0, 0, 1]), info: info, start: .none, end: .closedArrow)
        case "polygon": try writer.addPolygon(page, points, style: AnnotationStyle(color: [0, 0, 1], fill: [1, 0.8, 0.8]))
        case "cloud": try writer.addCloud(page, [(100, 600), (200, 600), (200, 700), (100, 700)])
        case "ink":
            try writer.addInk(page, [[(100, 600), (110, 620), (130, 625), (150, 610), (170, 640)], [(300, 600)]], style: AnnotationStyle(color: [0, 0, 0], width: 3, opacity: 0.4))
        case "freetext":
            try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "Hello, World (café)", font: FreeTextStyle(family: "Times New Roman", size: 14, font: .bold, textColor: [0, 0, 1], alignment: 1),
                                   style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [1, 1, 0.8]), info: info)
        case "freetext-wrap":
            try writer.addFreeText(page, PdfRect(100, 500, 220, 600), "The quick brown fox jumps over the lazy dog and keeps running\nSupercalifragilisticexpialidocious end", font: FreeTextStyle(size: 12))
        case "freetext-rich":
            let rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font-size:12pt;font-family:Helvetica\"><p>plain <span style=\"font-weight:bold;color:#FF0000\">loud</span> <i>slanted</i> <u>under</u></p><p>second<br/>third</p></body>"
            try writer.addFreeText(page, PdfRect(100, 600, 400, 660), "", font: FreeTextStyle(richText: rich))
        case "freetext-callout":
            try writer.addFreeText(page, PdfRect(300, 600, 400, 640), "see here", style: AnnotationStyle(color: [0, 0, 0], width: 1), callout: [(100, 500), (200, 500), (300, 620)])
        case "stamp": try writer.addStamp(page, PdfRect(100, 600, 300, 660), "Approved", info: info)
        case "stamp-custom": try writer.addStamp(page, PdfRect(100, 600, 300, 660), "Review me", color: [0, 0.4, 0])
        case "note": try writer.addNote(page, PdfRect(100, 700, 120, 720), info)
        case "note-comment": try writer.addNote(page, PdfRect(100, 700, 120, 720), info, icon: "Comment", color: [1, 0.5, 0])
        case "caret": try writer.addCaret(page, PdfRect(100, 600, 116, 616), info: info)
        case "attachments":
            for icon in ["PushPin", "Paperclip", "Graph", "Tag"] {
                try writer.addFileAttachment(page, PdfRect(100, 700, 116, 716), icon + ".txt", Array("data of \(icon)".utf8), info: info, icon: icon, mimeType: "text/plain")
            }
        case "redact": try writer.addRedact(page, quads, info: info, fill: [0, 0, 0], overlayText: "REDACTED")
        case "link":
            try writer.addLink(page, PdfRect(100, 600, 200, 620), UriAction("https://example.com"), style: AnnotationStyle(color: [0, 0, 1], width: 2))
            try writer.addLink(page, PdfRect(100, 500, 200, 520), PdfDestination(0, .fit))
        default: return ["unknown appearance \(name)"]
        }
        fix(document)
        return lines(try dump(document, from: 4))
    }

    private static func edit() throws -> [String] {
        let document = try AnnotationFixtures.blank(1)
        let writer = PdfAnnotationWriter(document)
        let page = document.pages[0]
        let ink = try writer.move(try writer.addInk(page, [[(100, 600), (120, 640)], [(200, 600), (220, 640)]]), 30, -10)
        let polygon = try writer.addPolygon(page, [(100, 600), (200, 600), (150, 700)], style: AnnotationStyle(width: 2))
        try writer.resize(polygon, PdfRect(polygon.rect.left, polygon.rect.bottom, polygon.rect.left + polygon.rect.width * 2, polygon.rect.bottom + polygon.rect.height / 2))
        let highlight = try writer.addTextMarkup(page, .highlight, [MarkupQuad.fromRect(PdfRect(100, 500, 300, 514))])
        try writer.setOpacity(try writer.setColor(highlight, [0, 1, 0]), 0.25)
        let note = try writer.addNote(page, PdfRect(10, 700, 30, 720), AnnotationInfo(author: "A", contents: "first"))
        try writer.setContents(note, "second", date: day)
        let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "styled")
        try writer.setFreeTextStyle(box, FreeTextStyle(family: "Courier New", size: 20, font: .bold, textColor: [1, 0, 0], alignment: 1))
        let gone = try writer.addSquare(page, PdfRect(1, 1, 50, 50))
        writer.delete(gone)
        fix(document)
        return lines(try dump(document, from: 4)) + ["ink " + numbers(ink.inkList[0]) + " " + ink.rect.toArray().description]
    }

    // A hand-written file with threads, states, dates and a rich text only comment.
    private static func threads() throws -> PdfDocument {
        try AnnotationFixtures.blank(2, { pdf in
            pdf.obj(20, "<</Subtype /Text /Rect [10 700 30 720] /T (Zed) /Contents (parent) /M (D:20260301090000Z) /NM (n20)>>")
            pdf.obj(21, "<</Subtype /Highlight /Rect [10 600 100 620] /T (alice) /Contents (marked) /M (D:20260301080000Z) /NM (n21)>>")
            pdf.obj(22, "<</Subtype /Text /Rect [10 700 30 720] /IRT 20 0 R /RT /R /T (bob) /Contents (reply) /StateModel (Review) /State (Accepted) /M (D:20260301100000Z)>>")
            pdf.obj(23, "<</Subtype /Text /Rect [10 700 30 720] /IRT 22 0 R /T (Carl) /Contents (second) /StateModel (Review) /State (Rejected) /M (D:20260301110000Z)>>")
            pdf.obj(24, "<</Subtype /Square /Rect [10 10 80 80] /T (Alice) /Contents (box)>>")
            pdf.obj(25, "<</Subtype /FreeText /Rect [100 100 200 200] /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one</p><p>two</p></body>) /M (D:20260301070000Z)>>")
            pdf.obj(26, "<</Subtype /Link /Rect [0 0 5 5]>>")
            pdf.obj(27, "<</Subtype /Text /Rect [200 700 220 720] /IRT 99 0 R /Contents (orphan) /T (ali)>>")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 26 0 R 27 0 R]")
    }

    private static func comments() throws -> [String] {
        let document = try threads()
        var results: [String] = []
        func one(_ c: PdfComment) -> String {
            "\(show(c.text ?? "-"))|\(show(c.author ?? "-"))|\(c.pageIndex)|\(c.status.rawValue)|\(c.replies.count)|\(iso(c.date))"
        }
        func list(_ filter: CommentFilter? = nil, _ order: CommentOrder = .page, _ descending: Bool = false) -> String {
            PdfComments.list(document, filter, order, descending: descending).map(one).joined(separator: " ; ")
        }
        for (name, order) in [("Page", CommentOrder.page), ("Date", .date), ("Author", .author), ("Type", .type)] {
            results.append("\(name) " + list(nil, order))
            results.append("\(name) descending " + list(nil, order, true))
        }
        results.append("author ali " + list(CommentFilter(author: "ALI")))
        results.append("text SECOND " + list(CommentFilter(text: "SECOND")))
        results.append("rejected " + list(CommentFilter(status: .rejected)))
        results.append("replies " + list(CommentFilter(hasReplies: true)))
        results.append("page 1 " + list(CommentFilter(pageIndex: 1)))
        results.append("types " + list(CommentFilter(types: [.square, .freeText])))

        guard let parent = PdfAnnotations.read(document, document.pages[0]).first(where: { $0.name == "n20" }) else { return results }
        let reply = try PdfComments.reply(document, parent, "agreed", "Can", day)
        let status = try PdfComments.setStatus(document, parent, .marked, "Deniz", DateTimeOffset(2026, 3, 4, 11, 0, 0))
        fix(document)
        results.append("reply " + reply.dictionary.description)
        results.append("status " + status.dictionary.description)
        results.append("after " + list())
        return results
    }

    private static func appearances(rotate: String = "") throws -> PdfDocument {
        try AnnotationFixtures.blank(1, { pdf in
            pdf.stream(4, "", "0.5 0 0 0.5 0 0 cm 1 0 0 rg q BT /F1 20 Tf 100 100 Td (Page) Tj ET")
            pdf.stream(30, "/Subtype /Form /BBox [0 0 50 50]", "0 0 50 50 re f")
            pdf.stream(31, "/Subtype /Form /BBox [0 0 10 20] /Matrix [0 1 -1 0 0 0]", "0 0 10 20 re f")
            pdf.stream(32, "/BBox [0 0 20 20]", "0 0 20 20 re f")
            pdf.obj(40, "<</Subtype /Square /Rect [10 10 60 60] /NM (a) /AP <</N 30 0 R>>>>")
            pdf.obj(41, "<</Subtype /Stamp /Rect [100 100 300 150] /NM (b) /AP <</N 31 0 R>> /F 4>>")
            pdf.obj(42, "<</Subtype /Text /Rect [200 200 220 220] /NM (c) /AP <</N 32 0 R>> /F 20 /Popup 43 0 R>>")
            pdf.obj(43, "<</Subtype /Popup /Rect [230 200 330 300] /Parent 42 0 R>>")
            pdf.obj(44, "<</Subtype /Text /Rect [200 200 220 220] /IRT 42 0 R /NM (d) /AP <</N 32 0 R>>>>")
            pdf.obj(45, "<</Subtype /Widget /Rect [300 300 320 320] /AS /On /AP <</N <</On 32 0 R /Off 30 0 R>>>>>>")
            pdf.obj(46, "<</Subtype /Link /Rect [0 0 5 5] /AP <</N 30 0 R>>>>")
            pdf.obj(47, "<</Subtype /Square /Rect [0 0 50 50] /F 2 /AP <</N 30 0 R>>>>")
            pdf.obj(48, "<</Subtype /Square /Rect [0 0 50 50]>>")
            pdf.obj(49, "<</Subtype /Square /Rect [70 70 90 90] /AP <</N 30 0 R>> /OC 50 0 R>>")
            pdf.obj(50, "<</Type /OCG /Name (hidden)>>")
        }, pageEntries: "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R 47 0 R 48 0 R 49 0 R] /Contents 4 0 R " + rotate)
    }

    private static func flatten(_ rest: String) throws -> [String] {
        let document = try appearances(rotate: rest == "rotated" ? "/Rotate 90" : "")
        var results: [String] = []
        if rest == "widgets" {
            results.append("count \(try PdfAnnotationFlattener.flatten(document, document.pages[0], [.widget]))")
        } else if rest == "links" {
            results.append("count \(try PdfAnnotationFlattener.flatten(document, document.pages[0], [.link, .square]))")
        } else {
            results.append("count \(try PdfAnnotationFlattener.flattenAll(document))")
        }
        results.append(contentsOf: lines(try dump(document, from: 3)))
        return results
    }

    // A file with a thread, a popup, an appearance stream and a rich text box, written by hand so that nothing in it is random.
    private static func marked() throws -> PdfDocument {
        let document = try AnnotationFixtures.blank(2, { pdf in
            pdf.stream(30, "/Type /XObject /Subtype /Form /BBox [0 0 200 60] /Resources <</Font <</F1 31 0 R>>>>", "BT /F1 12 Tf 5 5 Td (Approved) Tj ET")
            pdf.obj(31, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            pdf.obj(20, "<</Type /Annot /Subtype /Text /Rect [50 100 70 120] /Contents <FEFF015F0069> /T (Ay\\351e) /Subj (Review) /NM (note) /M (D:20260301090000Z) /CreationDate (D:20260301090000Z) /C [1 0.5 0] /F 28 /Name /Comment /Popup 21 0 R /P 3 0 R /StructParent 4>>")
            pdf.obj(21, "<</Type /Annot /Subtype /Popup /Rect [80 100 180 160] /Parent 20 0 R /Open true /NM (popup)>>")
            pdf.obj(22, "<</Type /Annot /Subtype /Text /Rect [50 100 70 120] /IRT 20 0 R /RT /R /Contents (reply) /T (Can) /NM (reply) /StateModel (Review) /State (Accepted) /F 30>>")
            pdf.obj(23, "<</Type /Annot /Subtype /Stamp /Rect [300 600 500 660] /Name /Approved /NM (stamp) /AP <</N 30 0 R>> /Dummy (x)>>")
            pdf.obj(24, "<</Type /Annot /Subtype /Highlight /Rect [50 700 150 714] /QuadPoints [50 714 150 714 50 700 150 700] /C [1 1 0] /CA 0.5 /NM (hl) /BS <</W 2 /S /D /D [3 1]>>>>")
            pdf.obj(25, "<</Type /Annot /Subtype /FreeText /Rect [100 100 300 140] /Contents (box) /DA (/Helv 12 Tf 0 g) /DS (font: Helvetica 12pt) /Q 1 /NM (ft) /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one &amp; <b>two</b></p></body>) /IC [1 1 0.8] /C [1 0 0] /RD [1 2 3 4] /LE [/Circle /ClosedArrow] /CL [1 2 3 4]>>")
            pdf.obj(26, "<</Type /Annot /Subtype /Line /Rect [10 10 110 60] /L [10 10 110 60] /LE [/Circle /ClosedArrow] /NM (ln) /BS <</W 2>> /IT /LineArrow>>")
            pdf.obj(27, "<</Type /Annot /Subtype /Ink /Rect [0 0 40 40] /InkList [[1 2 3 4] [5 6 7 8]] /NM (ink) /Open false>>")
            pdf.obj(28, "<</Type /Annot /Subtype /Circle /Rect [0 0 40 40] /BE <</S /C /I 2>> /NM (ci) /Vertices [1 2 3 4]>>")
            pdf.obj(29, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5]>>")
            pdf.obj(32, "<</Type /Annot /Subtype /Square /Rect [5 5 25 25] /NM (sq) /Q 7 /RT /Group /Sy /P /IT /Foo>>")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 29 0 R]")
        document.pages[1].dictionary["Annots"] = PdfArray([PdfReference(25, 0), PdfReference(26, 0), PdfReference(27, 0), PdfReference(28, 0), PdfReference(32, 0)])
        return document
    }

    private static func export() throws -> [String] {
        let document = try marked()
        let fdf = try PdfFdf.export(document, "book.pdf")
        var results: [String] = []
        for a in fdf.annotations { results.append("annotation page=\(a.pageIndex) \(a.dictionary)") }
        let bytes = try PdfFdf.write(fdf)
        results.append(contentsOf: showLines(Latin1.string(bytes)))
        let narrow = try PdfFdf.export(document, nil, types: [.highlight, .stamp]).annotations.map { ($0.dictionary["Subtype"] as? PdfName)?.value ?? "" }
        results.append("narrow " + narrow.joined(separator: ","))

        let target = try AnnotationFixtures.blank(2)
        let result = try PdfFdf.import(target, try PdfFdf.read(bytes))
        results.append("import \(result.imported) \(result.skipped) \(result.withoutAppearance)")
        results.append(contentsOf: lines(try dump(target, from: 4)))
        let again = try PdfFdf.import(target, try PdfFdf.read(bytes))
        results.append("again \(again.imported) \(again.skipped) \(again.withoutAppearance)")
        let xml = String(decoding: try PdfXfdf.write(fdf), as: UTF8.self)
        results.append(contentsOf: showLines(xml))
        let xfdf = try PdfXfdf.read(xml)
        results.append("xfdf \(xfdf.annotations.count) \(xfdf.fileName ?? "")")
        for a in xfdf.annotations { results.append("xannotation page=\(a.pageIndex) \(fold(a.dictionary))") }
        let target2 = try AnnotationFixtures.blank(2)
        let result2 = try PdfFdf.import(target2, xfdf)
        results.append("ximport \(result2.imported) \(result2.skipped) \(result2.withoutAppearance)")
        results.append(contentsOf: lines(try dump(target2, from: 4)))
        return results
    }

    // An FDF file read, shown, written again and turned into XFDF.
    private static func fdf(_ bytes: [UInt8]) throws -> [String] {
        let fdf = try PdfFdf.read(bytes)
        var results = ["file \(show(fdf.fileName ?? "-"))"]
        for f in fdf.flatFields() { results.append("field \(show(f.key)) \(f.value?.description ?? "")") }
        for a in fdf.annotations { results.append("annotation page=\(a.pageIndex) \(a.dictionary)") }
        results.append(contentsOf: showLines(Latin1.string(try PdfFdf.write(fdf))))
        results.append(contentsOf: showLines(String(decoding: try PdfXfdf.write(fdf), as: UTF8.self)))
        return results
    }

    // An XFDF file read, shown and written again.
    private static func xfdf(_ bytes: [UInt8]) throws -> [String] {
        let fdf = try PdfXfdf.read(bytes)
        var results = ["file \(show(fdf.fileName ?? "-"))"]
        for f in fdf.flatFields() { results.append("field \(show(f.key)) \(f.value?.description ?? "")") }
        for a in fdf.annotations { results.append("annotation page=\(a.pageIndex) \(fold(a.dictionary))") }
        results.append(contentsOf: showLines(String(decoding: try PdfXfdf.write(fdf), as: UTF8.self)))
        return results
    }

    private static func attach() throws -> [String] {
        let document = try StructureFixtures.open(2)
        let made = DateTimeOffset(2026, 5, 6, 7, 8, 9, offsetMinutes: 120)
        var results: [String] = []
        try PdfAttachments.add(document, "notes.txt", Array("short notes".utf8), mimeType: "text/plain", description: "Meeting notes", created: made,
                               modified: DateTimeOffset(2026, 5, 7, 7, 8, 9, offsetMinutes: 120))
        try PdfAttachments.add(document, "notes.txt", [1, 2, 3])
        try PdfAttachments.add(document, "dir/a.b.txt", [4])
        try PdfAttachments.add(document, "dir/a.b.txt", [5])
        try PdfAttachments.add(document, ".hidden", [6])
        try PdfAttachments.add(document, ".hidden", [7])
        try PdfAttachments.add(document, "end.", [8])
        try PdfAttachments.add(document, "end.", [9])
        try PdfAttachments.add(document, "Invoice: March.pdf", [10])
        try PdfAttachments.add(document, "Invoice: March.pdf", [11])
        try PdfAttachments.add(document, "a.b:c", [12])
        try PdfAttachments.add(document, "a.b:c", [13])
        for a in PdfAttachments.list(document) {
            results.append("item \(show(a.name))|\(show(a.fileName))|\(show(a.description ?? "-"))|\(a.mimeType ?? "-")|\(count(a.size))|\(count(a.storedSize))|\(iso(a.created))|\(iso(a.modified))|\(a.checkSum ?? "")|\(count(a.pageIndex))")
        }
        results.append(contentsOf: lines(try dump(document, from: 3)))
        let list = PdfAttachments.list(document)
        try PdfAttachments.remove(document, list[1])
        results.append("removed " + PdfAttachments.list(document).map { show($0.name) }.joined(separator: ","))
        for a in PdfAttachments.list(document) { try PdfAttachments.remove(document, a) }
        results.append("empty " + document.catalog.description)
        return results
    }

    private static func layers() throws -> [String] {
        let document = try StructureFixtures.file("/OCProperties <</OCGs [30 0 R 31 0 R 32 0 R 33 0 R] /D <</BaseState /OFF /ON [30 0 R] /Locked [32 0 R] /RBGroups [[30 0 R 31 0 R 33 0 R]] /Order [30 0 R (Group) [31 0 R 32 0 R]]>>>>") { pdf in
            pdf.obj(30, "<</Type /OCG /Name (Background) /Intent /View>>")
            pdf.obj(31, "<</Type /OCG /Name <FEFF0416> /Intent [/Design /View]>>")
            pdf.obj(32, "<</Type /OCG>>")
            pdf.obj(33, "<</Type /OCG /Name (Extra)>>")
        }
        var results: [String] = []
        func report(_ title: String) {
            let set = PdfLayers.read(document)
            let layers = set.layers.map { "\(show($0.name)):\($0.isOn ? "on" : "off"):\($0.locked ? "locked" : "-"):\($0.intent ?? "-")" }
            results.append(title + " " + layers.joined(separator: ","))
            results.append("order " + order(set.order).joined(separator: ","))
        }
        report("read")
        results.append("set " + b(PdfLayers.setVisible(document, PdfReference(31, 0), true)))
        report("31 on")
        results.append("set " + b(PdfLayers.setVisible(document, PdfReference(30, 0), true)))
        report("30 on")
        results.append("set " + b(PdfLayers.setVisible(document, PdfReference(33, 0), false)))
        report("33 off")
        results.append("set " + b(PdfLayers.setVisible(document, PdfReference(99, 0), false)))
        results.append(document.dict(document.catalog, "OCProperties")?.description ?? "")
        return results
    }

    private static func order(_ nodes: [LayerNode]) -> [String] {
        nodes.map { node in
            let label = node.label.map { "'" + show($0) + "'" } ?? ""
            let name = node.layer.map { show($0.name) } ?? ""
            return label + name + (node.children.isEmpty ? "" : "(" + order(node.children).joined(separator: ",") + ")")
        }
    }

    private static func facts(_ name: String) throws -> [String] {
        let document: PdfDocument
        switch name {
        case "everything":
            document = try StructureFixtures.file(
                "/Lang (en) /MarkInfo <</Marked true>> /OpenAction 30 0 R /Outlines 31 0 R /Collection <</View /T>> /AcroForm <</Fields [32 0 R] /SigFlags 3>> "
                + "/OCProperties <</OCGs [33 0 R 34 0 R]>> /Names <</EmbeddedFiles <</Names [(a) 35 0 R]>>>>") { pdf in
                pdf.obj(30, "<</S /JavaScript /JS (1)>>")
                pdf.obj(31, "<</First 36 0 R /Last 36 0 R /Count 1>>")
                pdf.obj(32, "<</FT /Tx /T (f)>>")
                pdf.obj(33, "<</Type /OCG /Name (a)>>")
                pdf.obj(34, "<</Type /OCG /Name (b)>>")
                pdf.stream(37, "", "x")
                pdf.obj(35, "<</F (a.txt) /EF <</F 37 0 R>>>>")
                pdf.obj(36, "<</Title (t)>>")
            }
        case "xfa":
            document = try StructureFixtures.file("/AcroForm <</Fields [] /XFA [(template) 30 0 R]>>") { $0.stream(30, "", "<x/>") }
        case "rotated":
            document = try StructureFixtures.file("", nil, pages: 2, pageEntries: "/Rotate 90 /UserUnit 2")
        default:
            document = try StructureFixtures.open(3)
        }
        let f = DocumentFacts.read(document)
        let form: String
        switch f.form {
        case .none: form = "None"
        case .acroForm: form = "AcroForm"
        case .xfa: form = "Xfa"
        }
        return [
            "\(f.version) \(f.fileSize) \(f.pageCount) \(n(f.firstPageWidth)) \(n(f.firstPageHeight)) lang=\(f.language ?? "-") tagged=\(b(f.isTagged)) linearized=\(b(f.isLinearized)) encrypted=\(b(f.isEncrypted)) signed=\(b(f.isSigned)) certified=\(b(f.isCertified))",
            "\(form) js=\(b(f.hasJavaScript)) bookmarks=\(b(f.hasBookmarks)) portfolio=\(b(f.isPortfolio)) attachments=\(f.attachmentCount) layers=\(f.layerCount) pdfa=\(f.pdfAPart.map { String($0) } ?? "-")/\(f.pdfAConformance ?? "-") repairs=\(f.repairCount) title=\(f.metadata.title ?? "-")",
            "text " + show(StructureText.formKindName(f.form)) + " " + show(StructureText.unnamedLayer) + " " + show(StructureText.newBookmark),
        ]
    }
}
