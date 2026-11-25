import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/ChangeRow.cs. One line of the change list. Boxes are in page space (points as
// shown, y down) of the page on their side; a side the change does not touch has none. `kind` is nil for a region found by
// the pixel comparison.

public struct ChangeRow: Identifiable {
    private static let maxBoxes = 200
    private static let maxTitle = 70

    public let id = UUID()
    public let kind: ChangeKind?
    public let title: String
    public let subtitle: String
    public let oldPage: Int
    public let newPage: Int
    public let oldBoxes: [ViewRect]
    public let newBoxes: [ViewRect]

    public init(kind: ChangeKind?, title: String, subtitle: String, oldPage: Int, newPage: Int, oldBoxes: [ViewRect], newBoxes: [ViewRect]) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.oldPage = oldPage
        self.newPage = newPage
        self.oldBoxes = oldBoxes
        self.newBoxes = newBoxes
    }

    public var spoken: String { title + ", " + subtitle }

    public var oldArea: ViewRect? { Self.union(oldBoxes) }

    public var newArea: ViewRect? { Self.union(newBoxes) }

    public static func of(_ change: CompareChange, _ before: PdfDocument, _ after: PdfDocument) -> ChangeRow {
        let title = change.area == .text ? textTitle(change) : change.detail ?? CompareText.areaName(change.area)
        let parts = [CompareText.kindName(change.kind), whereText(change.oldPage, change.newPage), change.area == .document ? values(change) : ""]
        return ChangeRow(kind: change.kind, title: title, subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                         oldPage: change.oldPage, newPage: change.newPage,
                         oldBoxes: boxes(before, change.oldPage, change.oldQuads), newBoxes: boxes(after, change.newPage, change.newQuads))
    }

    /// The region is in the new page's points; the old page's box is found by undoing what the comparer did to the old page.
    public static func of(_ pair: PagePair, _ difference: PixelDifference, _ alignment: PixelAlignment, _ dpi: Double,
                          _ before: PageGeometry, _ after: PageGeometry) -> ChangeRow {
        let region = difference.region
        let box = ViewRect(region.x, region.y, region.width, region.height)
        let down = after.height > 0 ? Int((min(max(box.y / after.height, 0), 1) * 100).rounded(.toNearestOrEven)) : 0
        return ChangeRow(kind: nil, title: L10n.t("Looks different"), subtitle: L10n.t("Page {0}, {1} % down", pair.newIndex + 1, down),
                         oldPage: pair.oldIndex, newPage: pair.newIndex, oldBoxes: [oldBox(box, alignment, dpi, before, after)], newBoxes: [box])
    }

    // The old page was resized to the new one, then turned about its centre and shifted; the mapping mirrors PixelAligner's.
    static func oldBox(_ box: ViewRect, _ alignment: PixelAlignment, _ dpi: Double, _ before: PageGeometry, _ after: PageGeometry) -> ViewRect {
        let toPoints = 72 / dpi, radians = alignment.degrees * Double.pi / 180
        let cos = Foundation.cos(radians), sin = Foundation.sin(radians), cx = after.width / 2, cy = after.height / 2
        var xs: [Double] = [], ys: [Double] = []
        for (x, y) in [(box.x, box.y), (box.x + box.width, box.y), (box.x, box.y + box.height), (box.x + box.width, box.y + box.height)] {
            let px = x - cx - alignment.shiftX * toPoints, py = y - cy - alignment.shiftY * toPoints
            xs.append((cos * px + sin * py + cx) * before.width / after.width)
            ys.append((-sin * px + cos * py + cy) * before.height / after.height)
        }
        let left = xs.min() ?? 0, top = ys.min() ?? 0
        return ViewRect(left, top, (xs.max() ?? 0) - left, (ys.max() ?? 0) - top)
    }

    private static func values(_ change: CompareChange) -> String {
        switch change.kind {
        case .added: return short(change.newText)
        case .removed: return short(change.oldText)
        default:
            return !change.oldText.isEmpty && !change.newText.isEmpty ? short(change.oldText + " → " + change.newText)
                : short(change.newText + change.oldText)
        }
    }

    private static func textTitle(_ change: CompareChange) -> String {
        if change.kind == .changed, !change.oldText.isEmpty, !change.newText.isEmpty { return short(change.oldText + " → " + change.newText) }
        return short(change.kind == .removed ? change.oldText : change.newText)
    }

    private static func short(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count <= maxTitle ? flat : String(flat.prefix(maxTitle - 1)) + "…"
    }

    private static func whereText(_ oldPage: Int, _ newPage: Int) -> String {
        if oldPage < 0 && newPage < 0 { return "" }
        if newPage < 0 { return L10n.t("Page {0} of the old file", oldPage + 1) }
        if oldPage < 0 || oldPage == newPage { return L10n.t("Page {0}", newPage + 1) }
        return L10n.t("Page {0}, was {1}", newPage + 1, oldPage + 1)
    }

    private static func boxes(_ document: PdfDocument, _ page: Int, _ quads: [TextQuad]) -> [ViewRect] {
        if page < 0 || page >= document.pages.count || quads.isEmpty { return [] }
        let geometry = PageGeometry(document.pages[page])
        return quads.prefix(maxBoxes).map { quad in
            let box = geometry.toDisplay(quad.bounds)
            return ViewRect(box.x, box.y, box.width, box.height)
        }
    }

    private static func union(_ boxes: [ViewRect]) -> ViewRect? {
        guard let first = boxes.first else { return nil }
        let left = boxes.reduce(first.x) { min($0, $1.x) }
        let top = boxes.reduce(first.y) { min($0, $1.y) }
        let right = boxes.reduce(first.x + first.width) { max($0, $1.x + $1.width) }
        let bottom = boxes.reduce(first.y + first.height) { max($0, $1.y + $1.height) }
        return ViewRect(left, top, right - left, bottom - top)
    }
}
