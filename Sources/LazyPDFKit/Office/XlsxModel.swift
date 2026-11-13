import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/XlsxModel.cs.

/// What a workbook may hold; a file over a limit is refused with a `PdfReadException`, except text, which is cut.
struct XlsxLimits {
    var maxSheets = 256
    var maxCells = 1_000_000
    var maxMergedRanges = 100_000
    var maxSharedStrings = 500_000
    var maxStyles = 64_000
    var maxNumberFormats = 2000
    var maxDefinedNames = 10_000
    var maxTextLength = 32_767
    var maxTotalText = 16_000_000

    static let maxRow = 1_048_576
    static let maxColumn = 16_384
    static let maxBreaks = 10_000
    static let maxFormatLength = 255
    static let standard = XlsxLimits()
}

enum XlsxSkipped {
    static let hiddenSheet = "hidden-sheet"
    static let chartSheet = "chart-sheet"
    static let otherSheet = "other-sheet"
    static let richText = "rich-text"
    static let fillPattern = "fill-pattern"
    static let textRotation = "text-rotation"
    static let formulaWithoutValue = "formula-no-value"
    static let cellOutsideGrid = "cell-outside-grid"
    static let longText = "long-text"
    static let picture = "sheet-picture"
    static let chart = "sheet-chart"
    static let shape = "sheet-shape"
    static let conditionalFormat = "conditional-format"
    static let sparkline = "sparkline"
    static let dataValidation = "data-validation"
    static let comment = "sheet-comment"
}

enum XlsxHorizontal: String { case general, left, center, right, fill, justify, centerContinuous, distributed }

enum XlsxVertical: String { case top, center, bottom, justify, distributed }

enum XlsxCellKind { case blank, number, text, bool, error }

/// A font as the styles part states it. `color` is 0xRRGGBB, or nil for the automatic color.
struct XlsxFont: Equatable {
    let name: String
    let size: Double
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let strike: Bool
    let color: Int?
}

/// A fill: the color of a solid fill (nil for none); `unsupported` when the file asks for a pattern or gradient, which is left out.
struct XlsxFill {
    let color: Int?
    let unsupported: Bool
}

/// One side of a border: the style name as the file writes it (thin, medium, dashed, ...) and the color, nil for automatic.
struct XlsxBorderEdge {
    let style: String
    let color: Int?
}

struct XlsxBorder {
    let left: XlsxBorderEdge?
    let right: XlsxBorderEdge?
    let top: XlsxBorderEdge?
    let bottom: XlsxBorderEdge?
}

/// A cell format (a cellXfs entry): the indexes into the font, fill and border lists and the alignment. Rotated text is not drawn rotated.
struct XlsxXf {
    let font: Int
    let fill: Int
    let border: Int
    let numberFormatId: Int
    let horizontal: XlsxHorizontal
    let vertical: XlsxVertical
    let wrap: Bool
    let indent: Int
    let rotated: Bool
}

/// A cell with its text already formatted. `color` is the color the number format asked for. `richFont` is the font of the
/// first run of a rich text cell, which replaces the font of the format.
struct XlsxCell {
    let column: Int
    let style: Int
    let kind: XlsxCellKind
    let text: String
    let color: Int?
    let richFont: XlsxFont?
}

final class XlsxRow {
    let index: Int
    /// Points, when the row states a height; nil leaves it to the content.
    var height: Double?
    var hidden = false
    var cells: [XlsxCell] = []

    init(_ index: Int) { self.index = index }
}

/// A run of columns `first` to `last` (1-based) that share a width in points.
struct XlsxColumns {
    let first: Int
    let last: Int
    let width: Double
    let hidden: Bool
}

/// A block of cells, 1-based and inclusive.
struct XlsxRange: Equatable {
    let firstRow: Int
    let firstColumn: Int
    let lastRow: Int
    let lastColumn: Int
}

/// How a sheet prints. Margins and distances are in points, the scale in percent.
final class XlsxPageSetup {
    var landscape = false
    /// The paper size code of pageSetup.
    var paper = 1
    var scale = 100
    var fitToPage = false
    var fitToWidth = 1
    /// 0 leaves the height to the content.
    var fitToHeight = 1
    var left = 50.4
    var right = 50.4
    var top = 54.0
    var bottom = 54.0
    var header = 21.6
    var footer = 21.6
    var centerHorizontally = false
    var centerVertically = false
    var gridlines = false
    var headings = false
    var overThenDown = false
    /// The number of the sheet's first page when it restarts the count, else nil.
    var firstPageNumber: Int?
    var differentOddEven = false
    var differentFirst = false
    var scaleWithDocument = true
    var alignWithMargins = true
    var oddHeader = ""
    var oddFooter = ""
    var evenHeader = ""
    var evenFooter = ""
    var firstHeader = ""
    var firstFooter = ""
    /// Manual breaks: the break comes after this row, or this column.
    var rowBreaks: [Int] = []
    var columnBreaks: [Int] = []
}

final class XlsxSheet {
    let name: String
    let setup = XlsxPageSetup()
    var rows: [XlsxRow] = []
    var columns: [XlsxColumns] = []
    var defaultColumnWidth = 0.0
    var defaultRowHeight = 15.0
    var merges: [XlsxRange] = []
    var printArea: [XlsxRange] = []
    /// The rows (first, last) and columns repeated on every page, nil for none.
    var titleRows: (first: Int, last: Int)?
    var titleColumns: (first: Int, last: Int)?

    init(name: String) { self.name = name }

    func width(of column: Int) -> Double {
        columns.first { column >= $0.first && column <= $0.last }?.width ?? defaultColumnWidth
    }

    func isColumnHidden(_ column: Int) -> Bool {
        columns.contains { column >= $0.first && column <= $0.last && $0.hidden }
    }
}

final class XlsxStyles {
    var fonts: [XlsxFont] = []
    var fills: [XlsxFill] = []
    var borders: [XlsxBorder] = []
    var xfs: [XlsxXf] = []
    /// Width in pixels of the widest digit of the default font, which column widths are counted in.
    var maxDigitWidth = 7
    var codes: [Int: String] = [:]
    private var parsed: [String: NumberFormat] = [:]

    func xf(_ index: Int) -> XlsxXf { index >= 0 && index < xfs.count ? xfs[index] : xfs[0] }

    func format(_ numberFormatId: Int) -> NumberFormat {
        guard let code = codes[numberFormatId] ?? NumberFormat.builtInCode(numberFormatId), code.utf16.count <= XlsxLimits.maxFormatLength else {
            return NumberFormat.general
        }
        if let known = parsed[code] { return known }
        let format = NumberFormat.parse(code)
        parsed[code] = format
        return format
    }
}

final class XlsxWorkbook {
    let date1904: Bool
    let styles: XlsxStyles
    var sheets: [XlsxSheet] = []
    var skipped: [SkippedFeature] = []

    init(date1904: Bool, styles: XlsxStyles) {
        self.date1904 = date1904
        self.styles = styles
    }
}
