import Foundation

// Twin of windows/LazyPDF.Core/Optimize/SanitizeText.cs: text a reader cannot see: white on a page that is blank under
// it, covered by a picture painted later, fully transparent, too small to read or outside the page or the clip
// (reported only), and text in render mode 3, which may be an OCR layer and goes only on request.

final class SanitizeText {
    private static let maxGlyphs = 100_000
    private static let maxPaints = 20_000
    private static let light: UInt8 = 247
    private static let legible = 1.0

    // A run is one text-showing operator: the form it is in (nil on the page) and its index there.
    private struct Run: Hashable {
        let form: ObjectIdentifier?
        let at: Int
    }

    private struct PageRun: Hashable {
        let page: Int
        let run: Run
    }

    private struct Glyph {
        let run: Run
        let bounds: PdfRect
        let white: Bool
        let unseen: Bool
        let mode: Int
        let order: Int
    }

    private struct Paint {
        let bounds: PdfRect
        let light: Bool
        let image: Bool
        let order: Int
    }

    private final class Scan: ContentVisitor {
        var glyphs: [Glyph] = []
        var paints: [Paint] = []
        private var order = 0

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if glyphs.count >= SanitizeText.maxGlyphs { return }
            let state = context.state
            let paint = state.renderMode & 3
            let color = paint == 1 ? state.strokeColor : state.fillColor
            let rgb = color.rgb
            let white = rgb.r >= SanitizeText.light && rgb.g >= SanitizeText.light && rgb.b >= SanitizeText.light
            let alpha = paint == 1 ? state.strokeAlpha : paint == 2 ? max(state.fillAlpha, state.strokeAlpha) : state.fillAlpha
            let box = glyph.bounds
            let clip = state.clip
            let unseen = alpha <= 0 || max(box.width, box.height) < SanitizeText.legible || clip.isEmpty
                || box.right < clip.left || box.left > clip.right || box.top < clip.bottom || box.bottom > clip.top
            let run = Run(form: context.forms.last.map { ObjectIdentifier($0) }, at: context.operatorIndex)
            glyphs.append(Glyph(run: run, bounds: box, white: white, unseen: unseen, mode: state.renderMode, order: order))
            order += 1
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if !path.fill || paints.count >= SanitizeText.maxPaints { return }
            let rgb = context.state.fillColor.rgb
            let light = SanitizeText.light
            paints.append(Paint(bounds: path.bounds, light: rgb.r >= light && rgb.g >= light && rgb.b >= light, image: false, order: order))
            order += 1
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if paints.count < SanitizeText.maxPaints {
                paints.append(Paint(bounds: image.bounds, light: false, image: !image.isMask && !image.dictionary.containsKey("SMask"), order: order))
                order += 1
            }
        }

        override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
            if paints.count < SanitizeText.maxPaints {
                paints.append(Paint(bounds: shading.bounds, light: false, image: false, order: order))
                order += 1
            }
        }
    }

    private let document: PdfDocument

    init(_ document: PdfDocument) {
        self.document = document
    }

    /// The runs of text a reader cannot see (hidden) and the runs in render mode 3 (invisible); a run is one text-showing operator.
    func count() -> (hidden: Int, invisible: Int) {
        var hidden = Set<PageRun>()
        var invisible = Set<PageRun>()
        var shown = Set<PageRun>()
        let interpreter = ContentInterpreter(document)
        for page in document.pages {
            let scan = Scan()
            interpreter.run(page, scan)
            let images = scan.paints.filter { $0.image }
            for glyph in scan.glyphs {
                let key = PageRun(page: page.index, run: glyph.run)
                if glyph.mode == 3 {
                    invisible.insert(key)
                    continue
                }
                if glyph.mode == 7 { continue }
                if !glyph.unseen { shown.insert(key) }
                if hidden.contains(key) { continue }
                let x = (glyph.bounds.left + glyph.bounds.right) / 2
                let y = (glyph.bounds.bottom + glyph.bounds.top) / 2
                let covered = images.contains { $0.order > glyph.order && Self.holds($0.bounds, glyph.bounds) }
                let blank = !covered && glyph.white && !scan.paints.contains { $0.order < glyph.order && !$0.light && Self.contains($0.bounds, x, y) }
                if covered || blank { hidden.insert(key) }
            }
            for glyph in scan.glyphs {
                let key = PageRun(page: page.index, run: glyph.run)
                if glyph.unseen && glyph.mode != 3 && glyph.mode != 7 && !shown.contains(key) { hidden.insert(key) }
            }
        }
        return (hidden.count, invisible.count)
    }

    private static func contains(_ box: PdfRect, _ x: Double, _ y: Double) -> Bool {
        x >= box.left && x <= box.right && y >= box.bottom && y <= box.top
    }

    private static func holds(_ outer: PdfRect, _ inner: PdfRect) -> Bool {
        inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5 && inner.bottom >= outer.bottom - 0.5 && inner.top <= outer.top + 0.5
    }

    /// Takes the text objects whose every show is in render mode 3 out of pages and forms; returns how many shows went.
    func strip() throws -> Int {
        var removed = 0
        for page in document.pages {
            guard let rebuilt = Self.rewrite(page.contents()) else { continue }
            removed += rebuilt.removed
            let stream = PdfStream(PdfDictionary(), data: [])
            PdfGraph.setData(stream, rebuilt.data)
            page.dictionary["Contents"] = try document.add(stream)
        }
        for (_, value) in PdfGraph.objects(document) {
            guard let stream = value as? PdfStream, document.name(stream.dictionary, "Subtype") == "Form" else { continue }
            let data: [UInt8]
            do {
                data = try document.data(stream)
            } catch {
                continue
            }
            guard let rebuilt = Self.rewrite(data) else { continue }
            removed += rebuilt.removed
            PdfGraph.setData(stream, rebuilt.data)
        }
        return removed
    }

    private static func rewrite(_ data: [UInt8]) -> (data: [UInt8], removed: Int)? {
        var hasTr = false
        if data.count >= 2 {
            for i in 0..<data.count - 1 where data[i] == 0x54 && data[i + 1] == 0x72 {
                hasTr = true
                break
            }
        }
        if !hasTr { return nil }
        let operations = ContentParser.parse(data)
        var saved: [Int] = []
        var mode = 0
        var edits: [(op: ContentOperation, text: String)] = []
        var segment: [(op: ContentOperation, mode: Int)] = []
        var inText = false
        for op in operations {
            switch op.operator {
            case "q":
                saved.append(mode)
            case "Q":
                if let previous = saved.popLast() { mode = previous }
            case "Tr":
                // (int) of a double saturates and reads NaN as 0 in .NET.
                if let m = op.number(0) { mode = m.isNaN ? 0 : Int(Swift.max(-2147483648, Swift.min(2147483647, m))) }
            case "BT":
                inText = true
                segment.removeAll()
            case "Tj", "TJ", "'", "\"":
                if inText { segment.append((op, mode)) }
            case "ET":
                inText = false
                if !segment.isEmpty && segment.allSatisfy({ $0.mode == 3 }) {
                    for shown in segment { edits.append((shown.op, replacement(shown.op))) }
                }
                segment.removeAll()
            default:
                break
            }
        }
        if edits.isEmpty { return nil }
        var output: [UInt8] = []
        var position = 0
        for edit in edits {
            if edit.op.start < position || edit.op.end > data.count { continue }
            output += data[position..<edit.op.start]
            output += Latin1.bytes(edit.text)
            position = edit.op.end
        }
        output += data[position...]
        return (output, edits.count)
    }

    // The line moves of ' and " stay, so text that follows is placed where it was.
    private static func replacement(_ op: ContentOperation) -> String {
        switch op.operator {
        case "'": return "T*"
        case "\"":
            let n = op.operands.count
            return n >= 3 ? "\(op.operands[n - 3]) Tw \(op.operands[n - 2]) Tc T*" : "T*"
        default: return ""
        }
    }
}
