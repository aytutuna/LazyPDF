import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Text/TextGolden.cs. One line of input is "<op> <words>" (the format is at the top
// of text-input.txt): one-page files and the fixture files turned into text pages and dumped, searches, and the tables
// of UTF-16 classification and folding that the search is built on, all as text. Numbers go through PdfNumber, which
// both sides write alike.
enum TextGolden {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

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
            case "page": return try pageOp(rest, TextPageOptions())
            case "pageopts": return try pageOptions(rest)
            case "search": return try search(rest)
            case "fixture": return try fixture(rest)
            case "text": return strings(rest)
            case "blocks": return blocks(rest)
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

    private static func r(_ r: PdfRect) -> String { "[\(n(r.left)) \(n(r.bottom)) \(n(r.right)) \(n(r.top))]" }

    private static func q(_ q: TextQuad) -> String {
        "[\(n(q.x0)) \(n(q.y0)) \(n(q.x1)) \(n(q.y1)) \(n(q.x2)) \(n(q.y2)) \(n(q.x3)) \(n(q.y3))]"
    }

    private static func b(_ value: Bool) -> String { value ? "1" : "0" }

    private static func hex(_ value: Int, _ width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // UTF-16 units in hex, so that no character is lost to the file's encoding.
    private static func u(_ text: String) -> String { u(Array(text.utf16)) }

    private static func u(_ units: [UInt16]) -> String { units.map { hex(Int($0), 4) }.joined(separator: " ") }

    private static func esc(_ text: String) -> String {
        var sb = ""
        for c in text.utf16 {
            switch c {
            case 0x5C: sb += "\\\\"
            case 0x0A: sb += "\\n"
            case 0x09: sb += "\\t"
            case 0x0C: sb += "\\f"
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

    private static func line(_ x: String, _ y: String, _ text: String, _ size: String) -> String {
        "BT /F1 \(size) Tf \(x) \(y) Td (\(text)) Tj ET\\n"
    }

    // {line X Y text}, {size S X Y text} and {col X TOP prefix N} stand for the content of TextTestPdf.Line and of a
    // column of lines 12 points apart.
    private static func expand(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var sb = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            guard chars[i] == "{", let close = chars[i...].firstIndex(of: "}") else {
                sb.append(chars[i])
                i += 1
                continue
            }
            let body = String(String.UnicodeScalarView(chars[(i + 1)..<close]))
            let w = body.components(separatedBy: " ")
            var made: String?
            if w[0] == "line" && w.count >= 4 {
                made = line(w[1], w[2], w[3...].joined(separator: " "), "10")
            } else if w[0] == "size" && w.count >= 5 {
                made = line(w[2], w[3], w[4...].joined(separator: " "), w[1])
            } else if w[0] == "col" && w.count == 5, let top = Int(w[2]), let count = Int(w[4]) {
                made = (0..<max(count, 0)).map { k in line(w[1], String(top - k * 12), "\(w[3]) line \(k + 1) of the column", "10") }.joined()
            }
            guard let made else {
                sb.append(chars[i])
                i += 1
                continue
            }
            sb.append(contentsOf: made.unicodeScalars)
            i = close + 1
        }
        return String(sb)
    }

    // code=hex,code=hex: the text of a code as UTF-16 units in hex, four digits each.
    private static func fontMap(_ text: String) -> [(Int, [UInt16])] {
        if text == "-" || text.isEmpty { return [] }
        return text.components(separatedBy: ",").map { entry in
            let parts = entry.components(separatedBy: "=")
            let digits = Array(parts[1].utf16)
            let units = stride(from: 0, to: digits.count / 4 * 4, by: 4).map { k in
                UInt16(String(units: Array(digits[k..<(k + 4)])), radix: 16) ?? 0
            }
            return (Int(parts[0]) ?? 0, units)
        }
    }

    // page <pageEntries> ;; <resources> ;; <content> ;; <object>...  where an object is "font N [code=hex,...]",
    // "obj N <text>" or "stream N <entries> :: <bytes>". "-" stands for nothing, and for the resources of /F1 as object 5.
    private static func build(_ fields: [String]) throws -> PdfDocument {
        let pageEntries = fields[0] == "-" ? "" : fields[0]
        let resources = fields[1] == "-" ? "/Font <</F1 5 0 R>>" : fields[1]
        let content = Golden.unescape(expand(fields[2]))
        let objects = Array(fields.dropFirst(3))
        let pdf = TestPdf()
        let catalog = objects.filter { $0.hasPrefix("catalog ") }.map { String($0.dropFirst(8)) + " " }.joined()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>> \(pageEntries)>>")
        pdf.stream(4, "", content)
        for field in objects where !field.hasPrefix("catalog ") {
            let w = field.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let number = Int(w[1]) ?? 0
            switch w[0] {
            case "font": TextTestPdf.font(pdf, number, units: fontMap(w.count > 2 ? w[2] : "-"))
            case "obj": pdf.obj(number, expand(w[2]))
            case "stream":
                if let split = w[2].range(of: " :: ") {
                    let entries = String(w[2][..<split.lowerBound])
                    pdf.stream(number, entries == "-" ? "" : entries, Golden.unescape(expand(String(w[2][split.upperBound...]))))
                }
            default: break
            }
        }
        return try PdfDocument.open(pdf.finish())
    }

    private static func pageOp(_ rest: String, _ options: TextPageOptions) throws -> [String] {
        let document = try build(rest.components(separatedBy: " ;; "))
        return dumpPage(TextPage.create(document, document.pages[0], options))
    }

    // pageopts <flags> ;; <page spec>: flags A (no artifacts), D (keep duplicates) and N (annotations).
    private static func pageOptions(_ rest: String) throws -> [String] {
        guard let split = rest.range(of: " ;; ") else { return [] }
        let flags = String(rest[..<split.lowerBound])
        let options = TextPageOptions(includeArtifacts: !flags.contains("A"), removeDuplicates: !flags.contains("D"), includeAnnotations: flags.contains("N"))
        return try pageOp(String(rest[split.upperBound...]), options)
    }

    private static func fixture(_ rest: String) throws -> [String] {
        let words = rest.components(separatedBy: " ")
        let url = folder.appendingPathComponent(words[0].contains("/") ? words[0] : "Documents/" + words[0])
        let document = try PdfDocument.open([UInt8](try Data(contentsOf: url)), password: words[1] == "-" ? nil : words[1])
        var lines: [String] = []
        let interpreter = ContentInterpreter(document)
        for i in 0..<document.pages.count {
            lines.append("page \(i)")
            lines.append(contentsOf: dumpPage(TextPage.create(interpreter, document.pages[i])))
        }
        return lines
    }

    private static func breakName(_ before: TextBreak) -> String {
        switch before {
        case .none: return "None"
        case .tab: return "Tab"
        case .line: return "Line"
        case .block: return "Block"
        }
    }

    private static func dumpPage(_ page: TextPage) -> [String] {
        var lines = [
            "page index=\(page.pageIndex) box=\(r(page.box)) truncated=\(b(page.isTruncated)) annotations=\(b(page.includesAnnotations)) "
                + "chars=\(page.chars.count) words=\(page.words.count) lines=\(page.lines.count) blocks=\(page.blocks.count)",
        ]
        for c in page.chars {
            let rgb = c.color
            lines.append("char \(c.index) u=\(u(c.text)) q=\(q(c.quad)) font=\(c.font?.name ?? "-") size=\(n(c.size)) rgb=\(rgb.r),\(rgb.g),\(rgb.b) mode=\(c.renderMode) op=\(c.operatorIndex) "
                + "form=\(b(c.form != nil)) el=\(c.element) off=\(c.offset) mcid=\(c.mcid.map { String($0) } ?? "-") art=\(b(c.isArtifact)) "
                + "space=\(b(c.isSpace)) implied=\(b(c.isImplied)) rtl=\(b(c.isRtl)) word=\(c.word) line=\(c.line)")
        }
        for w in page.words { lines.append("word \(w.index) [\(w.range.start),\(w.range.end)) u=\(u(w.text)) b=\(r(w.bounds)) line=\(w.line)") }
        for l in page.lines {
            lines.append("line \(l.index) [\(l.range.start),\(l.range.end)) u=\(u(l.text)) b=\(r(l.bounds)) q=\(q(l.quad)) block=\(l.block) before=\(breakName(l.before)) "
                + "vertical=\(b(l.isVertical)) rtl=\(b(l.isRtl))")
        }
        for k in page.blocks { lines.append("block \(k.index) lines=[\(k.lines.start),\(k.lines.end)) b=\(r(k.bounds)) table=\(b(k.isTable))") }
        lines.append("text \(esc(page.text))")
        lines.append("joined \(esc(page.getText(TextRange(0, page.chars.count), joinHyphens: true)))")
        lines.append("quads \(page.quads(TextRange(0, page.chars.count)).map { q($0) }.joined(separator: ";"))")
        let count = page.chars.count
        if count == 0 { return lines }
        var seen = Set<Int>()
        for i in [0, count / 3, count / 2, 2 * count / 3, count - 1] where seen.insert(i).inserted {
            let center = page.chars[i].quad.center
            for (x, y) in [(center.x, center.y), (center.x + 3, center.y - 2)] {
                let hit = page.hitTest(x, y)
                let shown = hit.map { "\($0.char)/\($0.word)/\($0.line)/\(n($0.distance))" } ?? "-"
                lines.append("probe \(i) p=\(n(x)),\(n(y)) hit=\(shown) caret=\(page.caretAt(x, y)) "
                    + "word=\(esc(TextSelection.wordAt(page, x, y).getText())) line=\(esc(TextSelection.lineAt(page, x, y).getText()))")
            }
        }
        let first = page.chars[0].quad.center
        let last = page.chars[count - 1].quad.center
        lines.append("between \(esc(TextSelection.between(page, first.x, first.y, last.x, last.y).getText()))")
        let box = page.box
        lines.append("rectangle \(esc(TextSelection.inRectangle(page, PdfRect(box.left, box.bottom + box.height / 2, box.right, box.top)).getText()))")
        return lines
    }

    // search <flags> ;; <query> ;; <page spec as in "page">. Flags are c (match case), w (whole word), r (regex) and f
    // (fold diacritics), or "-".
    private static func search(_ rest: String) throws -> [String] {
        let fields = rest.components(separatedBy: " ;; ")
        let options = TextSearchOptions(matchCase: fields[0].contains("c"), wholeWord: fields[0].contains("w"), regex: fields[0].contains("r"),
                                        foldDiacritics: fields[0].contains("f"))
        let document = try build(Array(fields.dropFirst(2)))
        let page = TextPage.create(document, document.pages[0])
        var lines: [String] = []
        do {
            for match in try TextSearch.find(page, str(fields[1]), options) {
                lines.append("match [\(match.range.start),\(match.range.end)) page=\(match.page) text=\(esc(match.text)) quads=\(match.quads.map { q($0) }.joined(separator: ";"))")
            }
        } catch {
            lines.append("bad pattern")
        }
        lines.append("count \(lines.count)")
        return lines
    }

    private static func className(_ cls: BidiClass) -> String {
        switch cls {
        case .l: return "L"
        case .r: return "R"
        case .en: return "EN"
        case .an: return "AN"
        case .n: return "N"
        }
    }

    // text <flags> <string>: what the search does to one string.
    private static func strings(_ rest: String) -> [String] {
        guard let space = rest.firstIndex(of: " ") else { return [] }
        let flags = String(rest[..<space])
        let text = str(String(rest[rest.index(after: space)...]))
        let options = TextSearchOptions(matchCase: flags.contains("c"), foldDiacritics: flags.contains("f"))
        return [
            "fold \(u(SearchText.fold(text, options)))",
            "strip \(u(SearchText.stripMarks(text)))",
            "clean \(u(TextNormal.clean(text)))",
            "collapse \(u(SearchText.collapse(text)))",
            "class \(className(TextBidi.classOf(text)))",
        ]
    }

    // blocks <kind>: for the blocks of 256 UTF-16 units below that have anything to say, the units a test is true for as
    // ranges, or what a unit becomes. Runtimes carry different versions of the Unicode data, and the blocks that got
    // letters or case pairs in versions 16 and 17 differ between them; these have not changed for years.
    private static let stableBlocks = [0x00, 0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x1E, 0x1F, 0x20, 0x21, 0x24, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF]

    private static func blocks(_ kind: String) -> [String] {
        var lines: [String] = []
        let plain = TextSearchOptions()
        let folding = TextSearchOptions(foldDiacritics: true)
        for block in stableBlocks {
            let line: String
            switch kind {
            case "letter": line = ranges(block) { $0.isLetter }
            case "lower": line = ranges(block) { $0.isLower }
            case "white": line = ranges(block) { $0.isWhiteSpace }
            case "mark": line = ranges(block) { $0.isNonSpacingMark }
            case "tolower": line = changes(block) { SearchText.fold([$0], plain) }
            case "toloweri": line = changes(block) { SearchText.fold([$0], folding) }
            case "strip": line = changes(block) { SearchText.stripMarks([$0]) }
            case "clean": line = changes(block) { Array(TextNormal.clean(String(units: [$0])).utf16) }
            default: line = ""
            }
            if !line.isEmpty { lines.append("\(hex(block, 2)) \(line)") }
        }
        return lines
    }

    private static func isSurrogate(_ unit: Int) -> Bool { unit >= 0xD800 && unit <= 0xDFFF }

    private static func ranges(_ block: Int, _ test: (UInt16) -> Bool) -> String {
        var parts: [String] = []
        var start = -1
        for i in 0...256 {
            let unit = block * 256 + i
            let on = i < 256 && test(UInt16(unit))
            if on && start < 0 {
                start = unit
            } else if !on && start >= 0 {
                parts.append(start == unit - 1 ? hex(start, 4) : "\(hex(start, 4))-\(hex(unit - 1, 4))")
                start = -1
            }
        }
        return parts.joined(separator: " ")
    }

    private static func changes(_ block: Int, _ map: (UInt16) -> [UInt16]) -> String {
        var parts: [String] = []
        for i in 0..<256 {
            let unit = block * 256 + i
            if isSurrogate(unit) { continue }
            let result = map(UInt16(unit))
            if result != [UInt16(unit)] { parts.append("\(hex(unit, 4))>\(u(result).replacingOccurrences(of: " ", with: "+"))") }
        }
        return parts.joined(separator: " ")
    }
}
