import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportModel.cs: the model every writer works from. A struct is a C# record of
// plain values; the blocks and the picture are classes, as the writers tell pictures apart by identity.
//
// Export layer decisions: the zip and PNG writers are the C# ones ported, deflate being the engine's own
// (`PdfFilterEncoders.flate`) where the C# uses `DeflateStream` and `ZLibStream`, so packages and PNGs hold other
// compressed bytes than the C# writes and are compared by what they decode to. Every writer builds its text in an
// `ExportBuilder`, which keeps the length in UTF-16 units that `StringBuilder.Length` gives the C# limits. A page
// index or a dpi out of range, and a pixel buffer that does not fit its size, are thrown as `ArgumentException`: a
// settings dialog or a codec can cause each. A Swift string cannot hold a lone UTF-16 surrogate, so text that held one
// in the C# holds U+FFFD here.

/// A stretch of text in one style. `size` is in points.
public struct ExportRun: Equatable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var size: Double

    public init(_ text: String, _ bold: Bool, _ italic: Bool, _ size: Double) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.size = size
    }
}

/// A picture kept as it is (JPEG) or as PNG (everything else, an /SMask as alpha).
public final class ExportImage {
    public let data: [UInt8]
    public let isJpeg: Bool
    public let width: Int
    public let height: Int

    public init(_ data: [UInt8], _ isJpeg: Bool, _ width: Int, _ height: Int) {
        self.data = data
        self.isJpeg = isJpeg
        self.width = width
        self.height = height
    }

    public var `extension`: String { isJpeg ? "jpg" : "png" }
    public var mimeType: String { isJpeg ? "image/jpeg" : "image/png" }
}

/// A piece of the flow of a page. Bounds are display points: origin top left, y down, the page as shown (crop box and
/// /Rotate applied).
public class ExportBlock {
    public let bounds: DisplayRect

    public init(_ bounds: DisplayRect) {
        self.bounds = bounds
    }
}

/// A paragraph, a heading (`heading` 1 to 6) or an item of a list.
public final class ExportParagraph: ExportBlock {
    public let runs: [ExportRun]
    public let heading: Int
    public let item: ExportListItem?

    public init(_ bounds: DisplayRect, _ runs: [ExportRun], _ heading: Int = 0, _ item: ExportListItem? = nil) {
        self.runs = runs
        self.heading = heading
        self.item = item
        super.init(bounds)
    }

    public var text: String { runs.map { $0.text }.joined() }
}

/// An item of a list. Items with the same `listId` are one list; `level` counts from 0, `number` is the number the item
/// carries in an ordered list.
public struct ExportListItem: Equatable {
    public let listId: Int
    public let ordered: Bool
    public let level: Int
    public let number: Int

    public init(_ listId: Int, _ ordered: Bool, _ level: Int, _ number: Int) {
        self.listId = listId
        self.ordered = ordered
        self.level = level
        self.number = number
    }
}

/// A table; every row has `columns` cells. `widths` are the column widths in points when the page showed them (ruled
/// tables), else nil. `ruled` says the page drew the grid.
public final class ExportTable: ExportBlock {
    public let rows: [[String]]
    public let widths: [Double]?
    public let ruled: Bool

    public init(_ bounds: DisplayRect, _ rows: [[String]], _ widths: [Double]?, _ ruled: Bool) {
        self.rows = rows
        self.widths = widths
        self.ruled = ruled
        super.init(bounds)
    }

    public var columns: Int { rows.first?.count ?? 0 }
}

public final class ExportPicture: ExportBlock {
    public let image: ExportImage

    public init(_ bounds: DisplayRect, _ image: ExportImage) {
        self.image = image
        super.init(bounds)
    }
}

/// One line of the page where it sits, for the layouts that keep positions.
public struct ExportTextLine {
    public let bounds: DisplayRect
    public let runs: [ExportRun]

    public init(_ bounds: DisplayRect, _ runs: [ExportRun]) {
        self.bounds = bounds
        self.runs = runs
    }

    public var text: String { runs.map { $0.text }.joined() }
}

/// A page in display points. `blocks` is the reflowed content in reading order, page headers and footers left out;
/// `lines` are all the text lines of the page with their places, `pictures` the pictures with theirs.
public struct ExportPage {
    public let index: Int
    public let width: Double
    public let height: Double
    public let blocks: [ExportBlock]
    public let lines: [ExportTextLine]
    public let pictures: [ExportPicture]

    public init(_ index: Int, _ width: Double, _ height: Double, _ blocks: [ExportBlock], _ lines: [ExportTextLine], _ pictures: [ExportPicture]) {
        self.index = index
        self.width = width
        self.height = height
        self.blocks = blocks
        self.lines = lines
        self.pictures = pictures
    }
}

/// The model every writer works from. `bodySize` is the size most text is set in, in points; `picturesLeftOut` how many
/// pictures the memory limits kept out of the pages.
public struct ExportDocument {
    public let title: String?
    public let pages: [ExportPage]
    public let bodySize: Double
    public let picturesLeftOut: Int

    public init(_ title: String?, _ pages: [ExportPage], _ bodySize: Double, _ picturesLeftOut: Int = 0) {
        self.title = title
        self.pages = pages
        self.bodySize = bodySize
        self.picturesLeftOut = picturesLeftOut
    }

    public var tables: [ExportTable] { pages.flatMap { $0.blocks.compactMap { $0 as? ExportTable } } }
}

/// The key of the counters of numbered lists: a Swift tuple is not hashable.
struct ListLevel: Hashable {
    let list: Int
    let level: Int
}
