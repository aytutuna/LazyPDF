import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Content/ContentGolden.cs. One line of input is "<op> <words>" (the format is at
// the top of content-input.txt): content streams parsed and written, one-page files run by the interpreter, fonts
// decoding bytes, and the fixture files run, all as text. Numbers go through PdfNumber, which both sides write alike.
enum ContentGolden {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

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
            case "parse": return parse(bytes(rest))
            case "write": return [Golden.escape(ContentWriter.write(ContentParser.parse(bytes(rest))))]
            case "run": return try runPage(rest)
            case "font": return try fonts(rest)
            case "fixture": return try fixture(rest)
            case "nest": return try nest(Int(rest) ?? 0)
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

    // {N*text} is text N times.
    private static func expand(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var j = i + 1
                while j < chars.count && chars[j].value >= 0x30 && chars[j].value <= 0x39 { j += 1 }
                let close = chars[j...].firstIndex(of: "}")
                if j > i + 1, j < chars.count, chars[j] == "*", let close {
                    let count = Int(String(String.UnicodeScalarView(chars[(i + 1)..<j]))) ?? 0
                    let unit = chars[(j + 1)..<close]
                    for _ in 0..<count { result.append(contentsOf: unit) }
                    i = close + 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return String(result)
    }

    private static func bytes(_ text: String) -> [UInt8] { Golden.unescape(expand(text)) }

    private static func latin(_ text: String) -> String { Latin1.string(bytes(text)) }

    private static func parse(_ data: [UInt8]) -> [String] {
        var lines: [String] = []
        for op in ContentParser.parse(data) {
            lines.append("op \(op.operator) [\(op.start),\(op.end)]" + (op.operands.isEmpty ? "" : " " + op.operands.map { $0.description }.joined(separator: " ")))
            guard let image = op.image else { continue }
            lines.append("image \(image.data.count) \(Golden.escape(image.data))")
            lines.append("dictionary \(image.dictionary)")
            lines.append("expanded \(image.expanded())")
        }
        return lines
    }

    private static func addObjects(_ pdf: TestPdf, _ fields: [String]) {
        for (i, raw) in fields.enumerated() {
            let field = expand(raw)
            guard field.hasPrefix("stream ") else {
                pdf.obj(5 + i, Latin1.string(Golden.unescape(field)))
                continue
            }
            let tail = String(field.dropFirst(6))
            guard let split = tail.range(of: " :: ") else { continue }
            let entries = Latin1.string(Golden.unescape(String(tail[..<split.lowerBound]))).trimmingCharacters(in: CharacterSet(charactersIn: " "))
            let data = String(tail[split.upperBound...])
            let content: [UInt8]
            if data.hasPrefix("file:") {
                let url = folder.appendingPathComponent("golden").appendingPathComponent(String(data.dropFirst(5)))
                content = (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
            } else {
                content = Golden.unescape(data)
            }
            pdf.stream(5 + i, entries, content)
        }
    }

    private static func runPage(_ rest: String) throws -> [String] {
        let fields = rest.components(separatedBy: " ;; ")
        let document = try ContentTestPdf.page(bytes(fields[1]), latin(fields[0])) { pdf in addObjects(pdf, Array(fields.dropFirst(2))) }
        return runAll(document, document.pages[0])
    }

    private static func fixture(_ rest: String) throws -> [String] {
        let words = rest.components(separatedBy: " ")
        let url = folder.appendingPathComponent("Documents").appendingPathComponent(words[0])
        let document = try PdfDocument.open([UInt8](try Data(contentsOf: url)), password: words[1] == "-" ? nil : words[1])
        var lines: [String] = []
        for i in 0..<document.pages.count {
            lines.append("page \(i)")
            lines.append(contentsOf: runAll(document, document.pages[i]))
        }
        return lines
    }

    private static func runAll(_ document: PdfDocument, _ page: PdfPage) -> [String] {
        let dump = Dump()
        let interpreter = ContentInterpreter(document)
        interpreter.run(page, dump)
        dump.flush()
        dump.lines.append("truncated \(flag(interpreter.isTruncated))")
        return dump.lines
    }

    private static func nest(_ count: Int) throws -> [String] {
        let names = (0..<count).map { "/F\($0) \(5 + $0) 0 R" }.joined(separator: " ")
        let document = try ContentTestPdf.page("/F0 Do", "/XObject <<\(names)>>") { pdf in
            for i in 0..<count { pdf.stream(5 + i, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0 0 1 1 re f /F\(i + 1) Do") }
        }
        let dump = Dump()
        ContentInterpreter(document).run(document.pages[0], dump)
        return ["paths \(dump.paths) depth \(dump.maxDepth)"]
    }

    private static func fonts(_ rest: String) throws -> [String] {
        let fields = rest.components(separatedBy: " ;; ")
        let document = try ContentTestPdf.page("", "") { pdf in addObjects(pdf, Array(fields.dropFirst())) }
        guard let dictionary = document.get(5) as? PdfDictionary else { return ["no font dictionary"] }
        let font = PdfFont.get(document, dictionary)
        var header = "font subtype=\(font.subtype) base=\(font.baseFont) name=\(font.name) composite=\(flag(font.isComposite)) type3=\(flag(font.isType3)) "
        header += "vertical=\(flag(font.isVertical)) embedded=\(flag(font.isEmbedded)) tounicode=\(flag(font.hasToUnicode)) flags=\(font.flags) "
        header += "bold=\(flag(font.isBold)) italic=\(flag(font.isItalic)) fixed=\(flag(font.isFixedPitch)) serif=\(flag(font.isSerif)) "
        header += "symbolic=\(flag(font.isSymbolic)) ascent=\(num(font.ascent)) descent=\(num(font.descent)) cap=\(num(font.capHeight)) "
        header += "matrix=\(mat(font.fontMatrix)) bbox=\(font.fontBBox.map { rect($0) } ?? "-")"
        var lines = [header]
        let input = fonts(hex: fields[0])
        for c in font.decode(input) {
            lines.append("char code=\(c.code) len=\(c.length) cid=\(c.cid) w=\(num(c.width)) u=\(uni(c.unicode)) space=\(flag(c.isSpace)) va=\(num(c.verticalAdvance)) "
                + "ox=\(num(c.originX)) oy=\(num(c.originY))")
        }
        lines.append("text \(uni(font.toText(input)))")
        return lines
    }

    private static func fonts(hex text: String) -> [UInt8] {
        let digits = text.unicodeScalars.compactMap { UInt8(String($0), radix: 16) }
        return stride(from: 0, to: digits.count - 1, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }

    private final class Dump: ContentVisitor {
        private var pending: String?
        private var repeats = 0

        var lines: [String] = []
        var paths = 0
        var maxDepth = 0

        func flush() {
            guard let pending else { return }
            lines.append(repeats > 1 ? "\(pending) x\(repeats)" : pending)
            self.pending = nil
        }

        private func add(_ line: String) {
            flush()
            lines.append(line)
        }

        // Runs of the same event are one line: a thousand marked-content levels are not a thousand lines.
        private func event(_ line: String) {
            if line == pending {
                repeats += 1
                return
            }
            flush()
            pending = line
            repeats = 1
        }

        private func at(_ c: ContentContext) -> String {
            "op=\(c.operatorIndex) forms=\(c.forms.count) mcid=\(c.mcid.map { String($0) } ?? "-")"
        }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            let c = glyph.character
            maxDepth = max(maxDepth, context.forms.count)
            add("glyph \(at(context)) code=\(c.code) len=\(c.length) cid=\(c.cid) w=\(num(c.width)) u=\(uni(c.unicode)) space=\(flag(c.isSpace)) va=\(num(c.verticalAdvance)) "
                + "ox=\(num(c.originX)) oy=\(num(c.originY)) m=\(mat(glyph.matrix)) box=\(rect(glyph.bounds)) adv=\(num(glyph.advance)) el=\(glyph.element) off=\(glyph.offset) \(stateText(context.state))")
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            paths += 1
            maxDepth = max(maxDepth, context.forms.count)
            add("path \(at(context)) \(path.operator) segs=\(segmentsText(path.segments)) bounds=\(rect(path.bounds)) ink=\(rect(path.inkBounds)) fill=\(flag(path.fill)) "
                + "stroke=\(flag(path.stroke)) eo=\(flag(path.evenOdd)) clips=\(flag(path.clips)) \(stateText(context.state))")
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            add("image \(at(context)) name=\(image.name ?? "-") inline=\(flag(image.inline != nil)) stream=\(flag(image.stream != nil)) w=\(image.width) h=\(image.height) "
                + "mask=\(flag(image.isMask)) oc=\(flag(image.optionalContent != nil)) m=\(mat(image.matrix)) bounds=\(rect(image.bounds)) dict=\(image.dictionary)")
        }

        override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
            add("shading \(at(context)) name=\(shading.name) bounds=\(rect(shading.bounds)) kind=\(shading.shading is PdfStream ? "stream" : "dictionary")")
        }

        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
            event("begin \(at(context)) tag=\(marked.tag) mcid=\(marked.mcid.map { String($0) } ?? "-") props=\(marked.properties.map { $0.description } ?? "-") oc=\(flag(marked.optionalContent != nil))")
        }

        override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
            event("end \(at(context)) tag=\(marked.tag)")
        }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) {
            add("\(form.isPattern ? "pattern" : "form") \(at(context)) name=\(form.name ?? "-") m=\(mat(form.matrix)) bounds=\(rect(form.bounds)) oc=\(flag(form.optionalContent != nil))")
        }

        override func endForm(_ context: ContentContext, _ form: FormInfo) {
            add("endform \(at(context))")
        }
    }
}

fileprivate func num(_ v: Double) -> String { PdfNumber(v).text }

fileprivate func mat(_ m: PdfMatrix) -> String { "[\(num(m.a)) \(num(m.b)) \(num(m.c)) \(num(m.d)) \(num(m.e)) \(num(m.f))]" }

fileprivate func rect(_ r: PdfRect) -> String { "[\(num(r.left)) \(num(r.bottom)) \(num(r.right)) \(num(r.top))]" }

fileprivate func flag(_ value: Bool) -> String { value ? "1" : "0" }

fileprivate func uni(_ text: String?) -> String {
    guard let text else { return "-" }
    return text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ",")
}

fileprivate func colorText(_ c: PdfColor) -> String {
    let rgb = c.rgb
    return "\(c.space.family)(\(c.components.map { num($0) }.joined(separator: ","))):\(rgb.r),\(rgb.g),\(rgb.b)" + (c.patternName.map { ":" + $0.value } ?? "")
}

fileprivate func stateText(_ s: GraphicsState) -> String {
    var text = "ctm=\(mat(s.ctm)) clip=\(rect(s.clip)) fill=\(colorText(s.fillColor)) stroke=\(colorText(s.strokeColor)) "
    text += "lw=\(num(s.lineWidth)) cap=\(s.lineCap) join=\(s.lineJoin) miter=\(num(s.miterLimit)) "
    text += "dash=[\(s.dash.map { num($0) }.joined(separator: ","))]@\(num(s.dashPhase)) alpha=\(num(s.fillAlpha))/\(num(s.strokeAlpha)) bm=\(s.blendMode) "
    text += "sm=\(flag(s.softMask != nil)) tc=\(num(s.charSpacing)) tw=\(num(s.wordSpacing)) tz=\(num(s.horizontalScale)) "
    text += "tl=\(num(s.leading)) ts=\(num(s.rise)) tr=\(s.renderMode) font=\(s.font?.name ?? "-") size=\(num(s.fontSize))"
    return text
}

fileprivate func segmentsText(_ segments: [PathSegment]) -> String {
    segments.map { s -> String in
        switch s.kind {
        case .move: return "M \(num(s.x1)) \(num(s.y1))"
        case .line: return "L \(num(s.x1)) \(num(s.y1))"
        case .curve: return "C \(num(s.x1)) \(num(s.y1)) \(num(s.x2)) \(num(s.y2)) \(num(s.x3)) \(num(s.y3))"
        case .close: return "Z"
        }
    }.joined(separator: ";")
}
