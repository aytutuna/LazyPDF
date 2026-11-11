import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/FigureFinder.cs: finds the figures of a tag tree and the box each one
// covers on its page.

/// A figure of the tag tree and the page it is on.
public struct FigureRow: Identifiable {
    public let element: StructElement
    public let page: Int
    public let number: Int

    public init(_ element: StructElement, _ page: Int, _ number: Int) {
        self.element = element
        self.page = page
        self.number = number
    }

    public var id: Int { number }

    /// What a draft is filed under: the object number of the figure, which a tag change elsewhere does not move.
    public var key: Int { element.reference?.number ?? -number }

    public var alt: String { element.alt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    public var hasAlt: Bool { !alt.isEmpty }

    private var replacement: String { element.actualText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// What the check counts as a description: alternate text or replacement text.
    public var hasDescription: Bool { hasAlt || !replacement.isEmpty }

    public var title: String { page >= 0 ? L10n.t("Figure {0}, page {1}", number, page + 1) : L10n.t("Figure {0}", number) }

    public var summary: String { hasAlt ? alt : !replacement.isEmpty ? replacement : L10n.t("No description") }

    public var automationName: String { title + ". " + summary }
}

public enum FigureFinder {
    public static func list(_ tree: StructureTree) -> [FigureRow] {
        var rows: [FigureRow] = []
        for element in tree.elements where tree.standardType(element.type) == "Figure" {
            rows.append(FigureRow(element, pageOf(element), rows.count + 1))
        }
        return rows
    }

    /// The page of the first thing the element holds, or -1.
    public static func pageOf(_ element: StructElement) -> Int {
        if element.pageIndex >= 0 { return element.pageIndex }
        var pending = [element]
        var budget = 2000
        while let next = pending.popLast(), budget > 0 {
            budget -= 1
            for kid in next.kids {
                if let content = kid as? StructContent, content.pageIndex >= 0 { return content.pageIndex }
                if let target = kid as? StructObject, target.pageIndex >= 0 { return target.pageIndex }
                if let child = kid as? StructElement { pending.append(child) }
            }
        }
        return -1
    }

    private struct Owned: Hashable {
        let stream: Int
        let mcid: Int
    }

    /// What the figure draws, in page space as shown: the pictures painted inside its marked content, else its drawing. Nil
    /// when the content cannot be found, as for a figure whose tag has no content of its own.
    public static func box(_ document: PdfDocument, _ figure: StructElement, _ page: Int) -> DisplayRect? {
        if page < 0 || page >= document.pages.count { return nil }
        var owned = Set<Owned>()
        var pending = [figure]
        var budget = 2000
        while let next = pending.popLast(), budget > 0 {
            budget -= 1
            for kid in next.kids {
                if let content = kid as? StructContent, content.pageIndex == page {
                    owned.insert(Owned(stream: content.stream?.number ?? 0, mcid: content.mcid))
                } else if let child = kid as? StructElement {
                    pending.append(child)
                }
            }
        }
        if owned.isEmpty { return nil }

        let finder = Finder(owned)
        ContentInterpreter(document).run(document.pages[page], finder)
        guard let found = finder.pictures ?? finder.drawing else { return nil }
        return PageGeometry(document.pages[page]).toDisplay(found)
    }

    private final class Finder: ContentVisitor {
        private let owned: Set<Owned>
        private var open: [(mark: MarkedContent, stream: Int)] = []

        var pictures: PdfRect?
        var drawing: PdfRect?

        init(_ owned: Set<Owned>) {
            self.owned = owned
            super.init()
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if owns() { pictures = Self.join(pictures, image.bounds) }
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if !path.clips && owns() { drawing = Self.join(drawing, path.inkBounds) }
        }

        // A sequence is numbered in the stream that holds its BDC, which can enclose the form being drawn.
        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
            open.append((marked, context.forms.last?.number ?? 0))
        }

        override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
            if !open.isEmpty { open.removeLast() }
        }

        private func owns() -> Bool {
            for entry in open.reversed() {
                if let mcid = entry.mark.mcid { return owned.contains(Owned(stream: entry.stream, mcid: mcid)) }
            }
            return false
        }

        private static func join(_ so: PdfRect?, _ box: PdfRect) -> PdfRect {
            guard let a = so else { return box }
            return PdfRect(min(a.left, box.left), min(a.bottom, box.bottom), max(a.right, box.right), max(a.top, box.top))
        }
    }
}
