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
    static let rightToLeftText = "rtl-text"
    static let complexScript = "complex-script"
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

    init() {}
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
    /// From the left of the text area, for a left aligned table.
    var indent = 0.0
    var align = LayoutAlign.left
    var rows: [LayoutRow] = []

    override init() {}
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

/// A run of pages with one geometry and one header and footer; it always starts on a new page.
final class LayoutSection {
    var page = LayoutGeometry()
    var header: [LayoutParagraph] = []
    var footer: [LayoutParagraph] = []
    var blocks: [LayoutBlock] = []

    init() {}
}

final class LayoutDocument {
    var sections: [LayoutSection] = []
    /// What the format reader left out; the layout adds its own to these.
    var skipped: [SkippedFeature] = []

    init() {}
}

/// A piece of one line in one style. `spaceExtra` is added after every space (justified lines).
struct PlacedText {
    let x: Double
    let baseline: Double
    let text: String
    let family: String
    let style: FontStyles
    let size: Double
    let color: Int
    let spaceExtra: Double
}

struct PlacedRect: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let color: Int
}

/// Positions are in points from the top left of the page.
enum LayoutBox {
    case text(PlacedText)
    case rect(PlacedRect)
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
