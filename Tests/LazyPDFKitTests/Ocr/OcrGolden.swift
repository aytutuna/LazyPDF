import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Ocr/OcrGolden.cs. One line of input is "<op> <rest>" (the format is at the top of
// ocr-input.txt): the glyphless font and its code tables, the reading order of words, the content stream of a layer on a
// page, the objects Add writes, and the kind of a page, all as text. Numbers go through PdfNumber, which both sides write alike.
enum OcrGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            let shown = line.utf16.count > 160 ? String(units: Array(line.utf16.prefix(160))) + "..." : line
            output += "> \(shown)\n"
            for result in try self.op(op, rest) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        do {
            switch op {
            case "font": return font(rest)
            case "cmap": return cmapOf(rest)
            case "flip": return [u(OcrVisualOrder.flip(str(rest)))]
            case "page": return pageOf(rest)
            case "place": return place(rest)
            case "add": return try add(rest)
            case "triage": return try triage(rest)
            case "layer": return try layer(rest)
            case "correct": return try correct(rest)
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

    private static func n(_ v: Double) -> String { PdfNumber(v).text }

    private static func hex(_ value: Int, _ width: Int, _ digits: String = "X") -> String {
        String(format: "%0\(width)l\(digits)", value)
    }

    // UTF-16 units in hex, so that no character is lost to the file's encoding.
    private static func u(_ text: String) -> String { text.utf16.map { hex(Int($0), 4) }.joined(separator: " ") }

    private static func hexBytes(_ bytes: [UInt8], _ from: Int, _ count: Int) -> String {
        bytes.dropFirst(from).prefix(count).map { hex(Int($0), 2, "x") }.joined()
    }

    private static func esc(_ text: String) -> String {
        var sb = ""
        for c in text.utf16 {
            switch c {
            case 0x5C: sb += "\\\\"
            case 0x0A: sb += "\\n"
            case 0x09: sb += "\\t"
            default:
                if c < 0x20 || c >= 0x7F {
                    sb += "\\u" + hex(Int(c), 4)
                } else {
                    sb.unicodeScalars.append(Unicode.Scalar(UInt8(c)))
                }
            }
        }
        return sb
    }

    // \uXXXX, \xHH, \n, \t and \\ in a string of the input.
    private static func str(_ text: String) -> String {
        let chars = Array(text.utf16)
        var sb: [UInt16] = []
        var i = 0
        while i < chars.count {
            if chars[i] != 0x5C || i + 1 >= chars.count {
                sb.append(chars[i])
                i += 1
                continue
            }
            i += 1
            let c = chars[i]
            switch c {
            case 0x6E: sb.append(0x0A)
            case 0x74: sb.append(0x09)
            case 0x75: // u
                sb.append(UInt16(String(units: Array(chars[(i + 1)..<min(i + 5, chars.count)])), radix: 16) ?? 0)
                i += 4
            case 0x78: // x
                sb.append(UInt16(String(units: Array(chars[(i + 1)..<min(i + 3, chars.count)])), radix: 16) ?? 0)
                i += 2
            default: sb.append(c)
            }
            i += 1
        }
        return String(units: sb)
    }

    private static func d(_ text: String) -> Double { Double(text) ?? 0 }

    // "text@x,y,width,height" or "text@x,y,width,height,confidence".
    private static func word(_ text: String) -> OcrWord {
        guard let at = text.lastIndex(of: "@") else { return OcrWord("", OcrBox(0, 0, 0, 0)) }
        let numbers = text[text.index(after: at)...].components(separatedBy: ",")
        let box = OcrBox(d(numbers[0]), d(numbers[1]), d(numbers[2]), d(numbers[3]))
        let words = str(String(text[..<at]))
        return numbers.count > 4 ? OcrWord(words, box, Float(numbers[4]) ?? 0) : OcrWord(words, box)
    }

    private static func words(_ parts: ArraySlice<String>) -> [OcrWord] { parts.filter { !$0.isEmpty }.map(word) }

    private static func split(_ rest: String) -> [String] { rest.components(separatedBy: " ;; ") }

    private static func font(_ kind: String) -> [String] {
        switch kind {
        case "program", "map":
            let bytes = kind == "program" ? GlyphlessFont.program : GlyphlessFont.cidToGidMap
            var lines = ["length \(bytes.count)"]
            for i in stride(from: 0, to: bytes.count, by: 64) { lines.append(hexBytes(bytes, i, 64)) }
            return lines
        case "ranges":
            return GlyphlessFont.identityRanges.components(separatedBy: "\n")
        default:
            return ["unknown font \(kind)"]
        }
    }

    // cmap <text>|<text>...: the codes of texts and the ToUnicode map apart from the ranges that never change.
    private static func cmapOf(_ rest: String) -> [String] {
        let texts = rest.components(separatedBy: "|").map(str)
        let codes = GlyphlessCodes.for(texts)
        var lines = ["supplementary " + codes.supplementary.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ")]
        for text in texts {
            lines.append("codes " + codes.codes(text).map { hex($0, 4) }.joined(separator: " ") + " covers " + (codes.covers(text) ? "1" : "0"))
            lines.append("bytes " + hexBytes(codes.bytes(text), 0, Int.max))
        }
        let map = codes.toUnicodeCMap()
        lines.append("map " + esc(map.replacingOccurrences(of: GlyphlessFont.identityRanges, with: "<ranges>\n")))
        return lines
    }

    private static func lines(_ lines: [OcrLine]) -> [String] {
        lines.map { l in
            "line \(esc(l.text)) [\(n(l.box.x)) \(n(l.box.y)) \(n(l.box.width)) \(n(l.box.height))] \(n(Double(l.confidence))) "
                + l.words.map { esc($0.text) }.joined(separator: ",")
        }
    }

    // page <pixel width> <pixel height> ;; <word> ;; <word> ...: lines, paragraphs and the texts of one page.
    private static func pageOf(_ rest: String) -> [String] {
        let parts = split(rest)
        let size = parts[0].components(separatedBy: " ")
        let page = OcrPage.of(words(parts.dropFirst()), Int(size[0]) ?? 0, Int(size[1]) ?? 0)
        var result = lines(page.lines)
        for p in OcrText.paragraphs(page) { result.append("paragraph \(p.lines.count) \(esc(p.text))") }
        result.append("pagetext " + esc(OcrText.pageText(page)))
        result.append("plaintext " + esc(OcrText.plainText([page, OcrPage.of([], 10, 10)])))
        return result
    }

    // place <rotate> <crop box or -> <user unit> <pixel width> <pixel height> ;; <word> ...: a layer's lines on a page
    // whose media box is 400 x 600, and the content stream written for them.
    private static func place(_ rest: String) -> [String] {
        let parts = split(rest)
        let head = parts[0].components(separatedBy: " ")
        let box = head[1] == "-" ? PdfRect(0, 0, 400, 600) : pdfBox(head[1])
        let unit = d(head[2])
        let geometry = PageGeometry(box, Int(head[0]) ?? 0, unit)
        let lines = OcrLayerContent.layout(words(parts.dropFirst()), Int(head[3]) ?? 0, Int(head[4]) ?? 0, geometry)
        var result = ["display \(n(geometry.width)) \(n(geometry.height))"]
        for line in lines {
            result.append("placed " + line.map { "\(esc($0.text)) [\(n($0.x)) \(n($0.y)) \(n($0.width)) \(n($0.height))]" }.joined(separator: " | "))
        }
        let codes = GlyphlessCodes.for(lines.flatMap { $0 }.map { $0.text })
        result.append("content " + esc(Latin1.string(OcrLayerContent.build(lines, geometry, unit > 0 ? unit : 1, codes))))
        return result
    }

    private static func pdfBox(_ text: String) -> PdfRect {
        let v = text.components(separatedBy: ",").map(d)
        return PdfRect(v[0], v[1], v[2], v[3])
    }

    private static func entries(_ text: String) -> String { text == "-" ? "" : text }

    // add <page entries or -> ;; <language> ;; <word> ...: Add on the scan of OcrKit, then the layer's stream and the objects of
    // the font, each as the file would write it, with the data of the streams decoded.
    private static func add(_ rest: String) throws -> [String] {
        let parts = split(rest)
        let document = try OcrKit.scan(1, entries(parts[0]))
        let geometry = PageGeometry(document.pages[0])
        let placed = try PdfOcrLayer.add(document, [OcrPageWords(0, words(parts.dropFirst(2)), Int(geometry.width), Int(geometry.height))], parts[1])
        var result = ["placed \(placed)"]
        let page = document.pages[0]
        result.append("contents " + (page.dictionary["Contents"]?.description ?? ""))
        result.append("fonts " + (document.dict(page.resources, "Font")?.description ?? ""))
        let items = (document.resolve(page.dictionary["Contents"]) as? PdfArray)?.items ?? []
        for item in items {
            guard let stream = document.resolve(item) as? PdfStream, stream.dictionary.containsKey("LazyPDFOcr") else { continue }
            result.append("layer " + stream.dictionary.description)
            result.append("stream " + esc(Latin1.string(try document.data(stream))))
        }
        guard let font = document.dict(document.dict(page.resources, "Font"), "LPOcrF") else { return result }
        result.append("font " + font.description)
        let cid = ((document.resolve(font["DescendantFonts"]) as? PdfArray)?.items.first).flatMap { document.resolve($0) as? PdfDictionary }
        result.append("cidfont " + (cid?.description ?? ""))
        let descriptor = document.dict(cid, "FontDescriptor")
        result.append("descriptor " + (descriptor?.description ?? ""))
        if let file = document.stream(descriptor, "FontFile2") {
            result.append("program " + (try document.data(file) == GlyphlessFont.program ? "same" : "different"))
        }
        if let map = document.stream(cid, "CIDToGIDMap") {
            result.append("map " + (try document.data(map) == GlyphlessFont.cidToGidMapData() ? "same" : "different"))
        }
        if let toUnicode = document.stream(font, "ToUnicode") {
            let text = Latin1.string(try document.data(toUnicode))
            result.append("tounicode " + esc(text.replacingOccurrences(of: GlyphlessFont.identityRanges, with: "<ranges>\n")))
        }
        return result
    }

    private static func wordLines(_ document: PdfDocument) throws -> [String] {
        try PdfOcrLayer.words(document, document.pages[0]).map {
            "word \($0.index) \(esc($0.text)) [\(n($0.box.x)) \(n($0.box.y)) \(n($0.box.width)) \(n($0.box.height))]"
        }
    }

    // layer <page entries or -> ;; <content>: the words read from a layer stream written by hand with that content.
    private static func layer(_ rest: String) throws -> [String] {
        let parts = split(rest)
        let document = try OcrKit.scan(1, entries(parts[0]))
        try OcrKit.addLayer(document, Latin1.string(Golden.unescape(parts[1])))
        return try wordLines(document)
    }

    // correct <page entries or -> ;; <index> ;; <text> ;; <word> ...: Add on the scan, then Correct; the words read back, the
    // layer's stream decoded and the characters beyond the BMP the font carries, by code.
    private static func correct(_ rest: String) throws -> [String] {
        let parts = split(rest)
        let document = try OcrKit.scan(1, entries(parts[0]))
        let geometry = PageGeometry(document.pages[0])
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, words(parts.dropFirst(3)), Int(geometry.width), Int(geometry.height))], "en")
        let page = document.pages[0]
        try PdfOcrLayer.correct(document, page, Int(parts[1]) ?? 0, str(parts[2]))
        var result = try wordLines(document)
        let items = (document.resolve(page.dictionary["Contents"]) as? PdfArray)?.items ?? []
        for item in items {
            if let stream = document.resolve(item) as? PdfStream, stream.dictionary.containsKey("LazyPDFOcr") {
                result.append("stream " + esc(Latin1.string(try document.data(stream))))
            }
        }
        let font = OcrLayerContent.fontOf(document, page, "LPOcrF")
        let supplementary = font.map { GlyphlessCodes.from($0).supplementary.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ") }
        result.append("supplementary " + (supplementary ?? "none"))
        return result
    }

    // triage <page entries or -> ;; <content>: the kind of the page of OcrKit.scan that draws the content.
    private static func triage(_ rest: String) throws -> [String] {
        let parts = split(rest)
        let document = try OcrKit.scan(1, entries(parts[0]), Latin1.string(Golden.unescape(parts[1])))
        switch OcrTriage.classify(document, document.pages[0]) {
        case .blank: return ["Blank"]
        case .drawing: return ["Drawing"]
        case .picture: return ["Picture"]
        case .ownLayer: return ["OwnLayer"]
        case .foreignLayer: return ["ForeignLayer"]
        case .text: return ["Text"]
        }
    }
}
