import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageObjects.cs: something painted on a page that an editor can select: a block of
// text, an image or a path.

public enum PageObjectKind {
    case text
    case image
    case path
}

public enum TextAlignment {
    case left
    case center
    case right
    case justify
}

/// Something painted on a page that an editor can select: a block of text, an image or a path.
/// Bounds are in user space. An object is a snapshot; it is stale once the page has been edited
/// and the editor has read it again.
public class PageObject {
    init(_ id: Int, _ kind: PageObjectKind, _ bounds: PdfRect, _ unit: ContentUnit, _ visit: FormVisit?, _ sequence: Int) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.unit = unit
        self.visit = visit
        self.sequence = sequence
    }

    /// Position in `PageEditor.objects`, which runs in painting order.
    public let id: Int

    public let kind: PageObjectKind
    public let bounds: PdfRect

    /// The form XObjects the object sits in, outermost first; empty for the page itself.
    public var forms: [PdfStream] { visit?.chain ?? [] }

    let unit: ContentUnit
    let visit: FormVisit?
    let sequence: Int
}

/// A line of a text block: its characters in `TextPage.chars` and the box it covers.
public struct TextObjectLine: Equatable {
    public let index: Int
    public let range: TextRange
    public let text: String
    public let bounds: PdfRect

    public init(index: Int, range: TextRange, text: String, bounds: PdfRect) {
        self.index = index
        self.range = range
        self.text = text
        self.bounds = bounds
    }
}

/// A paragraph, column piece or table of the page's text, as `TextPage` finds it.
public final class TextObject: PageObject {
    init(_ id: Int, _ bounds: PdfRect, _ unit: ContentUnit, _ visit: FormVisit?, _ sequence: Int, _ block: TextBlock) {
        self.block = block
        super.init(id, .text, bounds, unit, visit, sequence)
    }

    let block: TextBlock
    var glyphs: [EditGlyph] = []

    /// Index of the block in `TextPage.blocks`.
    public var blockIndex: Int { block.index }

    public internal(set) var lines: [TextObjectLine] = []
    public internal(set) var text = ""

    /// The characters of the block in `TextPage.chars`.
    public internal(set) var range = TextRange(0, 0)

    /// Font, size (user space units), colour and character spacing of the first glyph.
    public internal(set) var font: PdfFont?
    public internal(set) var size = 0.0
    public internal(set) var color = RgbColor(0, 0, 0)
    public internal(set) var charSpacing = 0.0

    public internal(set) var alignment = TextAlignment.left

    /// Distance between the baselines of the first two lines; 0 for a single line.
    public internal(set) var lineSpacing = 0.0

    public var isTable: Bool { block.isTable }
}

public final class ImageObject: PageObject {
    init(_ id: Int, _ bounds: PdfRect, _ unit: ContentUnit, _ visit: FormVisit?, _ sequence: Int, _ info: ImageInfo, _ opacity: Double, _ op: Int) {
        self.info = info
        self.opacity = opacity
        self.op = op
        super.init(id, .image, bounds, unit, visit, sequence)
    }

    let info: ImageInfo
    let op: Int

    /// The resource name; nil for an inline image.
    public var name: String? { info.name }

    public var width: Int { info.width }
    public var height: Int { info.height }
    public var isInline: Bool { info.inline != nil }
    public var isMask: Bool { info.isMask }

    /// Maps the unit square the image fills to user space: where it sits, how large and turned.
    public var placement: PdfMatrix { info.matrix }

    /// Fill alpha in force when it is painted.
    public let opacity: Double
}

public final class PathObject: PageObject {
    init(_ id: Int, _ bounds: PdfRect, _ unit: ContentUnit, _ visit: FormVisit?, _ sequence: Int, _ info: PathInfo, _ style: PathStyle, _ firstOp: Int, _ paintOp: Int) {
        self.info = info
        self.style = style
        self.firstOp = firstOp
        self.paintOp = paintOp
        super.init(id, .path, bounds, unit, visit, sequence)
    }

    let info: PathInfo
    let style: PathStyle
    let firstOp: Int
    let paintOp: Int

    public var segments: [PathSegment] { info.segments }
    public var fill: Bool { info.fill }
    public var stroke: Bool { info.stroke }
    public var evenOdd: Bool { info.evenOdd }

    /// The path also sets the clip; such a path cannot be moved or changed apart from deleting it.
    public var clips: Bool { info.clips }

    public var fillColor: RgbColor { style.fill }
    public var strokeColor: RgbColor { style.stroke }
    public var lineWidth: Double { style.lineWidth }
    public var opacity: Double { style.opacity }
}
