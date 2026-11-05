import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/ReadingOrder.cs: the text a screen reader would meet, in the order the tags
// give it.
//
// The C# keys its dictionaries by tuples; Swift tuples are not Hashable, so each key is a small struct.

private struct PieceKey: Hashable {
    let stream: Int
    let mcid: Int
}

private struct NamedKey: Hashable {
    let page: Int
    let stream: Int
    let mcid: Int
}

private struct DrawingKey: Hashable {
    let stream: Int
    let op: Int
    let element: Int
    let offset: Int
}

private struct CornerKey: Hashable {
    let drawing: DrawingKey
    let x: Double
    let y: Double
}

public enum ReadingOrder {
    private static let inline: Set<String> = ["Span", "Link", "Quote", "Code", "Reference", "Note", "BibEntry", "Em", "Strong", "Sub", "Ruby", "Warichu"]

    /// One line per block: headings after as many `#` as their level, a list item with its label, a table row with its cells
    /// apart by tabs, a figure as `[Figure: alt text]`. Artifacts are not in the tags and so not here. Empty when the document
    /// has no tags; pass `tree` to use one already read.
    public static func export(_ document: PdfDocument, _ tree: StructureTree? = nil) -> String {
        guard let tree = tree ?? StructureTree.read(document) else { return "" }
        let walker = Walker(document, tree)
        for root in tree.roots { walker.visit(root) }
        return walker.result()
    }

    private final class Piece {
        var text = ""
        var line = -1
    }

    private final class Walker {
        private let document: PdfDocument
        private let tree: StructureTree
        private var pages: [Int: [PieceKey: Piece]] = [:]
        private let named: Set<NamedKey>
        private var lines: [String] = []
        private var line = ""

        init(_ document: PdfDocument, _ tree: StructureTree) {
            self.document = document
            self.tree = tree
            named = Set(tree.contents.map { NamedKey(page: $0.pageIndex, stream: $0.stream?.number ?? 0, mcid: $0.mcid) })
        }

        func result() -> String {
            lines.joined(separator: "\n")
        }

        func visit(_ element: StructElement) {
            let type = tree.standardType(element.type)
            switch type {
            case "Figure":
                flush()
                let alt = !DotNetText.isNullOrWhiteSpace(element.alt) ? DotNetText.trim(element.alt ?? "") : everything(element)
                let label = AccessibilityText.figureLabel
                lines.append(alt.isEmpty ? "[\(label)]" : "[\(label): \(alt)]")
                return
            case "TR":
                flush()
                lines.append(element.children.map { everything($0) }.joined(separator: "\t"))
                return
            case "LI":
                flush()
                lines.append(everything(element))
                return
            default:
                break
            }

            flush()
            let units = Array(type.utf16)
            if units.count == 2 && units[0] == 0x48 && DotNetText.isDigit(units[1]) {
                line += String(repeating: "#", count: Int(units[1]) - 0x30) + " "
            }
            for kid in element.kids {
                if let content = kid as? StructContent {
                    append(&line, content)
                } else if let child = kid as? StructElement, ReadingOrder.inline.contains(tree.standardType(child.type)) {
                    line += everything(child)
                } else if let block = kid as? StructElement {
                    flush()
                    visit(block)
                }
            }
            flush()
        }

        private func flush() {
            let text = DotNetText.words(line)
            line = ""
            if !text.isEmpty && !text.utf16.allSatisfy({ $0 == 0x23 }) { lines.append(text) }
        }

        // The element's own words: its content and everything below it, in order.
        private func everything(_ element: StructElement) -> String {
            var text = ""
            var stack: [StructKid] = Array(element.kids.reversed())
            var budget = 100_000
            while !stack.isEmpty {
                budget -= 1
                if budget <= 0 { break }
                guard let kid = stack.popLast() else { break }
                if let content = kid as? StructContent {
                    append(&text, content)
                } else if let child = kid as? StructElement {
                    if tree.standardType(child.type) != "Figure" && !text.isEmpty && text.utf16.last != 0x20 { text += " " }
                    stack.append(contentsOf: child.kids.reversed())
                }
            }
            return DotNetText.words(text)
        }

        private func append(_ into: inout String, _ content: StructContent) {
            if content.pageIndex < 0 || content.pageIndex >= document.pages.count { return }
            let pieces: [PieceKey: Piece]
            if let known = pages[content.pageIndex] {
                pieces = known
            } else {
                pieces = read(document.pages[content.pageIndex])
                pages[content.pageIndex] = pieces
            }
            if let piece = pieces[PieceKey(stream: content.stream?.number ?? 0, mcid: content.mcid)] {
                into += piece.text
                into += " "
            }
        }

        // Characters by the sequence that holds them: the innermost one around the glyph that the tree names, each in the stream that numbers it.
        private func read(_ page: PdfPage) -> [PieceKey: Piece] {
            let text = TextPage.create(document, page)
            let owners = Owners({ self.named.contains($0) }, page.index)
            let interpreter = ContentInterpreter(document)
            interpreter.walkPatterns = false
            interpreter.run(page, owners)
            var pieces: [PieceKey: Piece] = [:]
            let chars = text.chars
            var keys = [PieceKey?](repeating: nil, count: chars.count)
            for i in 0..<chars.count where !chars[i].isImplied {
                keys[i] = owners.ownerOf(chars[i])
            }
            for i in 0..<chars.count {
                if chars[i].isImplied && i > 0 && i + 1 < chars.count {
                    if let before = keys[i - 1], keys[i + 1] == before { keys[i] = before } else { keys[i] = nil }
                }
                if let found = keys[i] { add(&pieces, found, chars[i]) }
            }
            return pieces
        }

        private func add(_ pieces: inout [PieceKey: Piece], _ key: PieceKey, _ c: TextChar) {
            let piece: Piece
            if let known = pieces[key] {
                piece = known
            } else {
                piece = Piece()
                pieces[key] = piece
            }
            if piece.line >= 0 && piece.line != c.line && !piece.text.isEmpty && piece.text.utf16.last != 0x20 { piece.text += " " }
            piece.line = c.line
            piece.text += c.text
        }
    }

    // Finds, for each glyph the text page keeps, the innermost open sequence the tree names; a sequence is numbered in the stream that holds its BDC.
    // The text collector decides which glyphs count (clip, render mode 7, hidden layers), so a drawing the page does not show is never an owner.
    private final class Owners: ContentVisitor {
        private static let maxNear = 64

        private let named: (NamedKey) -> Bool
        private let page: Int
        private let shown = TextCollector(TextPageOptions())
        private var open: [(mark: MarkedContent, stream: Int)] = []

        // A form drawn twice shows the same operator and offset twice, so the drawings are told apart by the corner the collector puts on the glyph.
        private var exact: [CornerKey: PieceKey?] = [:]

        // A glyph under /ActualText is merged with its neighbours and its box no longer matches a drawing; the nearest of the first few drawings serves.
        private var near: [DrawingKey: [(x: Double, y: Double, owner: PieceKey?)]] = [:]

        init(_ named: @escaping (NamedKey) -> Bool, _ page: Int) {
            self.named = named
            self.page = page
            super.init()
        }

        func ownerOf(_ c: TextChar) -> PieceKey? {
            let key = DrawingKey(stream: c.form?.number ?? 0, op: c.operatorIndex, element: c.element, offset: c.offset)
            let (x, y) = (c.quad.x0, c.quad.y0)
            if let owner = exact[CornerKey(drawing: key, x: x, y: y)] { return owner }
            guard let drawn = near[key] else { return nil }
            return drawn.min { ($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y) < ($1.x - x) * ($1.x - x) + ($1.y - y) * ($1.y - y) }?.owner
        }

        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
            shown.beginMarked(context, marked)
            open.append((marked, context.forms.last?.number ?? 0))
        }

        override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
            shown.endMarked(context, marked)
            _ = open.popLast()
        }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) {
            shown.beginForm(context, form)
        }

        override func endForm(_ context: ContentContext, _ form: FormInfo) {
            shown.endForm(context, form)
        }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            let before = shown.glyphs.count
            shown.showGlyph(context, glyph)
            if shown.glyphs.count == before { return }

            var owner: PieceKey?
            var i = open.count - 1
            while i >= 0 && owner == nil {
                if let mcid = open[i].mark.mcid, named(NamedKey(page: page, stream: open[i].stream, mcid: mcid)) {
                    owner = PieceKey(stream: open[i].stream, mcid: mcid)
                }
                i -= 1
            }
            guard let g = shown.glyphs.last else { return }
            let key = DrawingKey(stream: g.form?.number ?? 0, op: g.op, element: g.element, offset: g.offset)
            let corner = CornerKey(drawing: key, x: g.quad.x0, y: g.quad.y0)
            if exact.index(forKey: corner) == nil { exact.updateValue(owner, forKey: corner) }
            if (near[key]?.count ?? 0) < Self.maxNear { near[key, default: []].append((g.quad.x0, g.quad.y0, owner)) }
        }
    }
}
