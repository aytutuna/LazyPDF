import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureTree.Boxes.cs: where an element's content is on the pages.

/// Where a piece of an element's content is on a page, in the page's user space (before /Rotate).
public struct ElementBox {
    public let pageIndex: Int
    public let rect: PdfRect
}

/// The boxes of an element's content in tree order; `isCapped` when the element had more than was looked at.
public struct ElementBoxes {
    public let boxes: [ElementBox]
    public let isCapped: Bool
}

private struct BoxKey: Hashable {
    let stream: Int
    let mcid: Int
}

private struct PageBoxKey: Hashable {
    let page: Int
    let stream: Int
    let mcid: Int
}

extension StructureTree {
    private static let maxBoxKids = 20_000
    private static let maxBoxPages = 100
    private static let maxBoxes = 500

    /// The page rectangles of the marked content under `element`, for showing it on the page: one box per sequence, around
    /// what the sequence draws (the page's own content and form XObjects drawn there), and the /Rect of each annotation the
    /// element holds. A sequence that draws nothing has no box. The walk stops at 20 000 kids, 100 pages and 500 boxes, and
    /// says so.
    public func boxes(_ element: StructElement) -> ElementBoxes {
        var capped = false
        var wanted: [StructKid] = []
        for e in Self.subtree(element) {
            for kid in e.kidList where !(kid is StructElement) {
                if wanted.count >= Self.maxBoxKids { capped = true } else { wanted.append(kid) }
            }
        }

        var drawn: [PageBoxKey: PdfRect] = [:]
        let pageCount = document.pages.count
        var pages: [Int] = []
        var keysByPage: [Int: Set<BoxKey>] = [:]
        for case let c as StructContent in wanted where c.pageIndex >= 0 && c.pageIndex < pageCount {
            if keysByPage[c.pageIndex] == nil { pages.append(c.pageIndex) }
            keysByPage[c.pageIndex, default: []].insert(BoxKey(stream: c.stream?.number ?? 0, mcid: c.mcid))
        }
        if pages.count > Self.maxBoxPages {
            capped = true
            pages = Array(pages[0..<Self.maxBoxPages])
        }
        for page in pages {
            let boxer = Boxer(keysByPage[page] ?? [])
            let interpreter = ContentInterpreter(document)
            interpreter.walkPatterns = false
            interpreter.run(document.pages[page], boxer)
            for (key, rect) in boxer.found { drawn[PageBoxKey(page: page, stream: key.stream, mcid: key.mcid)] = rect }
        }

        var boxes: [ElementBox] = []
        for kid in wanted {
            var rect: PdfRect?
            var page = -1
            if let c = kid as? StructContent {
                rect = drawn[PageBoxKey(page: c.pageIndex, stream: c.stream?.number ?? 0, mcid: c.mcid)]
                page = c.pageIndex
            } else if let o = kid as? StructObject {
                rect = document.rect(document.resolve(o.target) as? PdfDictionary, "Rect")
                page = o.pageIndex
            }
            guard let rect else { continue }
            if boxes.count >= Self.maxBoxes {
                capped = true
                break
            }
            boxes.append(ElementBox(pageIndex: page, rect: rect))
        }
        return ElementBoxes(boxes: boxes, isCapped: capped)
    }

    // What a sequence draws goes to the innermost /MCID sequence around it, the way ReadingOrder gives a glyph an owner.
    private final class Boxer: ContentVisitor {
        private let keys: Set<BoxKey>
        private var open: [(stream: Int, mcid: Int?)] = []

        fileprivate var found: [BoxKey: PdfRect] = [:]

        init(_ keys: Set<BoxKey>) {
            self.keys = keys
            super.init()
        }

        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
            open.append((context.forms.last?.number ?? 0, marked.mcid))
        }

        override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
            open.removeLast()
        }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) { add(glyph.bounds) }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if path.fill || path.stroke { add(path.inkBounds) }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) { add(image.bounds) }

        private func add(_ bounds: PdfRect) {
            for entry in open.reversed() {
                guard let mcid = entry.mcid else { continue }
                let key = BoxKey(stream: entry.stream, mcid: mcid)
                if keys.contains(key) {
                    if let have = found[key] {
                        found[key] = PdfRect(Swift.min(have.left, bounds.left), Swift.min(have.bottom, bounds.bottom), Swift.max(have.right, bounds.right), Swift.max(have.top, bounds.top))
                    } else {
                        found[key] = bounds
                    }
                }
                return
            }
        }
    }
}
