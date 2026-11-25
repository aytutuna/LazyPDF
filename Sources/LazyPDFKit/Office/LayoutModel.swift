import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/LayoutModel.cs: the converter's layout model, in points.

/// A PDF made from an Office file: its bytes, page count, what was left out and the code points no font could draw.
public struct OfficePdf {
    public let bytes: [UInt8]
    public let pages: Int
    public let skipped: [SkippedFeature]
    public let missing: [Int]

    public init(_ bytes: [UInt8], _ pages: Int, _ skipped: [SkippedFeature], _ missing: [Int]) {
        self.bytes = bytes
        self.pages = pages
        self.skipped = skipped
        self.missing = missing
    }
}

/// Something in the source the converter did not carry over: a stable `kind` code and how many times it occurred.
public struct SkippedFeature: Equatable {
    public let kind: String
    public var count: Int

    public init(_ kind: String, _ count: Int) {
        self.kind = kind
        self.count = count
    }
}

enum SkippedKinds {
    static let complexScript = "complex-script"
    static let unreadablePicture = "picture"
}

enum LayoutAlign { case left, center, right, justify }

enum LineRule { case multiple, exact, atLeast }

enum LayoutField { case none, pageNumber, pageCount }

/// Text in one style. In a header or footer a field run is replaced by the page number or the page count.
final class LayoutRun {
    var text = ""
    var family = OfficeFontSource.defaultFamily
    var size = 11.0
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// 0xRRGGBB.
    var color = 0
    var highlight: Int?
    /// Points above the baseline; negative sinks the text. The size is already the reduced one.
    var shift = 0.0
    var field = LayoutField.none
    /// The run is right to left: the characters in it that have no direction of their own go with the right-to-left text.
    var rtl = false
    /// A picture in line with the text; then the text is empty and the font only sets the descent of the line.
    var picture: LayoutPicture?

    init() {}
}

/// The bytes of a picture file. A picture used more than once shares one object, which is how the writer finds that it is one image.
final class PictureFile {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }
}

/// A picture file as the document holds it and the size it takes on the page, in points. The crop edges are the fractions of the picture cut off on each side.
final class LayoutPicture {
    let file: PictureFile
    let width: Double
    let height: Double
    let cropLeft: Double
    let cropTop: Double
    let cropRight: Double
    let cropBottom: Double

    init(_ file: PictureFile, _ width: Double, _ height: Double, cropLeft: Double = 0, cropTop: Double = 0, cropRight: Double = 0, cropBottom: Double = 0) {
        self.file = file
        self.width = width
        self.height = height
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.cropRight = cropRight
        self.cropBottom = cropBottom
    }
}

class LayoutBlock {}

final class LayoutPageBreak: LayoutBlock {}

/// A paragraph. Text may hold \n for a line break and \t for a tab.
final class LayoutParagraph: LayoutBlock {
    var runs: [LayoutRun] = []
    var align = LayoutAlign.left
    var left = 0.0
    var right = 0.0
    /// Added to `left` for the first line; negative hangs it.
    var firstLine = 0.0
    var before = 0.0
    var after = 0.0
    /// A factor for `LineRule.multiple`, else points.
    var lineSpacing = 1.0
    var rule = LineRule.multiple
    var keepWithNext = false
    var pageBreakBefore = false
    var widowControl = true
    /// A tab stop, from the text area, for the tab after a list number; that tab is the first one of the paragraph.
    var labelTab: Double?
    /// The paragraph runs right to left. `left`, `right` and `firstLine` then count from the start (right) and end (left)
    /// edges, while `align` stays physical.
    var rightToLeft = false

    override init() {}
}

/// A line of a cell edge: its thickness in points and 0xRRGGBB.
struct LayoutBorder: Equatable {
    let width: Double
    let color: Int
}

enum LayoutVAlign { case top, center, bottom }

/// A cell, placed on the table's grid. `rowSpan` counts the rows a vertical merge covers; the cells that continue it are
/// not kept. The borders are the ones left after the two cells at an edge have been compared.
final class LayoutCell {
    var column = 0
    var span = 1
    var rowSpan = 1
    var paragraphs: [LayoutParagraph] = []
    var fill: Int?
    var top: LayoutBorder?
    var right: LayoutBorder?
    var bottom: LayoutBorder?
    var left: LayoutBorder?
    var marginTop = 0.0
    var marginRight = 5.4
    var marginBottom = 0.0
    var marginLeft = 5.4
    var vAlign = LayoutVAlign.top

    init() {}
}

final class LayoutRow {
    var cells: [LayoutCell] = []
    /// Repeated at the top of every page the table continues on.
    var header = false
    var cantSplit = false
    var height = 0.0
    /// The height is fixed and what does not fit in it is not drawn; else it is a minimum.
    var heightExact = false

    init() {}
}

/// A table. A column of 0 has no width of its own and shares what the others leave.
final class LayoutTable: LayoutBlock {
    var columns: [Double] = []
    /// From the left of the text area, for a left aligned table; from the right for a right aligned one when the table is right to left.
    var indent = 0.0
    var align = LayoutAlign.left
    /// The table's columns run right to left, so the indent belongs to the right edge. `mirror()` has put the cells there; this only moves the indent.
    var rightToLeft = false
    var rows: [LayoutRow] = []

    override init() {}

    /// Turns a table written from its start edge into one drawn right to left: the columns, the cells' places, borders and margins swap sides.
    func mirror() {
        columns.reverse()
        for cell in rows.flatMap({ $0.cells }) {
            cell.column = columns.count - cell.column - cell.span
            swap(&cell.left, &cell.right)
            swap(&cell.marginLeft, &cell.marginRight)
        }
    }
}

/// Sizes in points. Header and footer distances are measured from the page edge to the band.
struct LayoutGeometry {
    var width = 595.28
    var height = 841.89
    var top = 72.0
    var right = 72.0
    var bottom = 72.0
    var left = 72.0
    var headerDistance = 36.0
    var footerDistance = 36.0
}

enum PageVariant: Int { case standard = 0, first, even }

/// A run of pages with one geometry and one header and footer; it always starts on a new page.
final class LayoutSection {
    var page = LayoutGeometry()
    var header: [LayoutParagraph] = []
    var footer: [LayoutParagraph] = []
    /// The first page of the section has its own bands.
    var titlePage = false
    /// Even pages, counted from the start of the document, have their own bands.
    var evenAndOdd = false
    var firstHeader: [LayoutParagraph] = []
    var firstFooter: [LayoutParagraph] = []
    var evenHeader: [LayoutParagraph] = []
    var evenFooter: [LayoutParagraph] = []
    var blocks: [LayoutBlock] = []

    init() {}

    func headerOf(_ variant: PageVariant) -> [LayoutParagraph] {
        switch variant {
        case .first: return firstHeader
        case .even: return evenHeader
        case .standard: return header
        }
    }

    func footerOf(_ variant: PageVariant) -> [LayoutParagraph] {
        switch variant {
        case .first: return firstFooter
        case .even: return evenFooter
        case .standard: return footer
        }
    }
}

final class LayoutDocument {
    var sections: [LayoutSection] = []
    /// What the format reader left out; the layout adds its own to these.
    var skipped: [SkippedFeature] = []

    init() {}
}

/// A piece of one line in one style. `spaceExtra` is added after every space (justified lines). `rightToLeft`: the text
/// is one right-to-left run in logical order, drawn from x to the right in display order.
struct PlacedText {
    let x: Double
    let baseline: Double
    let text: String
    let family: String
    let style: FontStyles
    let size: Double
    let color: Int
    let spaceExtra: Double
    var rightToLeft = false
}

/// A picture with its top left corner at x, y. It is turned clockwise by `rotation` degrees about its center after it has
/// been mirrored left to right, if it is.
struct PlacedImage {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let source: LayoutPicture
    var rotation = 0.0
    var flipH = false
}

struct PlacedRect: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let color: Int
}

/// One step of an outline. A move or a line ends at x, y; a curve is a cubic Bezier through x1, y1 and x2, y2 to x, y.
enum PathCommand: Equatable {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

/// An outline: its width, 0xRRGGBB and the dash pattern in points (on, off, on, off ...; empty is solid).
struct PathStroke {
    let width: Double
    let color: Int
    let dash: [Double]
}

/// An outline in page points that is filled, stroked or both.
struct PlacedPath {
    let commands: [PathCommand]
    let fill: Int?
    let stroke: PathStroke?
}

/// Positions are in points from the top left of the page.
enum LayoutBox {
    case text(PlacedText)
    case rect(PlacedRect)
    case image(PlacedImage)
    case path(PlacedPath)
}

struct LayoutPage {
    let width: Double
    let height: Double
    let boxes: [LayoutBox]
}

struct LayoutResult {
    let pages: [LayoutPage]
    let skipped: [SkippedFeature]
    let missing: [Int]
}
