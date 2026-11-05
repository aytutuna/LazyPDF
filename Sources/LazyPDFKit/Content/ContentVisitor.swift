import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentVisitor.cs: what a `ContentInterpreter` reports. Every method of the
// visitor does nothing until overridden; each gets the `ContentContext` that says where it comes from.

/// An open marked-content sequence (ISO 32000-1 14.6): `BMC` or `BDC` up to its `EMC`. A class, as the interpreter
/// tells its overflow marker apart by identity.
public final class MarkedContent {
    /// The tag, such as `Span`, `OC` or `Artifact`.
    public let tag: String

    /// The property dictionary of a `BDC`, inline or looked up in /Properties; nil for `BMC` or a name that does not resolve.
    public let properties: PdfDictionary?

    /// /MCID of the properties, the key into the structure tree.
    public let mcid: Int?

    /// For tag `OC`: the optional content group or membership dictionary the properties name.
    public let optionalContent: PdfDictionary?

    public init(_ tag: String, _ properties: PdfDictionary?, _ mcid: Int?, _ optionalContent: PdfDictionary?) {
        self.tag = tag
        self.properties = properties
        self.mcid = mcid
        self.optionalContent = optionalContent
    }
}

/// Where a callback comes from and what was true when it came. The object is the interpreter's own and changes with
/// the walk, so a visitor copies what it keeps.
public final class ContentContext {
    init(_ document: PdfDocument, _ state: GraphicsState) {
        self.document = document
        self.state = state
    }

    public let document: PdfDocument

    /// The graphics state before the operator ran, except for text, where it is the state the glyph is drawn in.
    public internal(set) var state: GraphicsState

    /// The form XObjects (and tiling patterns) being run, outermost first; empty on the page itself. With
    /// `operatorIndex` this finds the operation: parse the page's `PdfPage.contents()`, or `PdfDocument.data(_:)` of
    /// the last form.
    public internal(set) var forms: [PdfStream] = []

    /// Index of the running operation in the parse of the content stream it belongs to.
    public internal(set) var operatorIndex = 0

    public internal(set) var operation = ContentOperation("", [], 0, 0)

    /// Open marked-content sequences, outermost first, those of enclosing streams included.
    public internal(set) var marked: [MarkedContent] = []

    /// The text matrix and text line matrix (9.4.2); identity outside a text object.
    public internal(set) var textMatrix = PdfMatrix.identity
    public internal(set) var textLineMatrix = PdfMatrix.identity

    /// The innermost /MCID among the open sequences, or nil.
    public var mcid: Int? { marked.last(where: { $0.mcid != nil })?.mcid }

    /// The innermost optional content dictionary among the open sequences, or nil.
    public var optionalContent: PdfDictionary? { marked.last(where: { $0.optionalContent != nil })?.optionalContent }
}

/// A glyph shown by `Tj`, `TJ`, `'` or `"`.
public struct GlyphInfo {
    /// Code, length, CID, width and Unicode of the character.
    public let character: FontChar

    /// The font in force.
    public let font: PdfFont

    /// Maps the em square of the glyph (origin at the glyph origin, one unit the font size) to the space the content
    /// started in: the text rendering matrix (9.4.4), with a vertical font's origin shift applied.
    public let matrix: PdfMatrix

    /// The box of the glyph's advance by the font's ascent and descent, in that space.
    public let bounds: PdfRect

    /// How far the text matrix moves after the glyph, in text space: along x, or along y for a vertical font.
    /// Character and word spacing and horizontal scaling are included.
    public let advance: Double

    /// Index of the string among the operands: 0 for Tj, the array item for TJ, 0 for ' and 1 for ".
    public let element: Int

    /// Byte position of the code in that string.
    public let offset: Int

    public init(_ character: FontChar, _ font: PdfFont, _ matrix: PdfMatrix, _ bounds: PdfRect, _ advance: Double, _ element: Int, _ offset: Int) {
        self.character = character
        self.font = font
        self.matrix = matrix
        self.bounds = bounds
        self.advance = advance
        self.element = element
        self.offset = offset
    }

    public var code: Int { character.code }
    public var unicode: String? { character.unicode }
}

/// One segment of a path, with the points already transformed by the matrix in force when it was added.
public struct PathSegment: Equatable {
    public let kind: PathSegmentKind
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double
    public let x3: Double
    public let y3: Double

    public init(_ kind: PathSegmentKind, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
        self.kind = kind
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.x3 = x3
        self.y3 = y3
    }
}

public enum PathSegmentKind {
    case move
    case line
    /// A cubic Bezier: control points 1 and 2, then the end point.
    case curve
    case close
}

/// A path painted or turned into a clip.
public struct PathInfo {
    /// The painting operator: S, s, f, F, f*, B, B*, b, b* or n (a path that only clips).
    public let `operator`: String

    /// The path in the space the content started in.
    public let segments: [PathSegment]

    /// The box of its points, control points of curves included.
    public let bounds: PdfRect

    /// The same grown by half the line width when it is stroked.
    public let inkBounds: PdfRect

    public let fill: Bool
    public let stroke: Bool
    public let evenOdd: Bool
    public let clips: Bool

    public init(_ op: String, _ segments: [PathSegment], _ bounds: PdfRect, _ inkBounds: PdfRect, _ fill: Bool, _ stroke: Bool, _ evenOdd: Bool, _ clips: Bool) {
        self.operator = op
        self.segments = segments
        self.bounds = bounds
        self.inkBounds = inkBounds
        self.fill = fill
        self.stroke = stroke
        self.evenOdd = evenOdd
        self.clips = clips
    }
}

/// An image painted by `Do` or `BI`.
public struct ImageInfo {
    /// The resource name; nil for an inline image.
    public let name: String?

    /// The image XObject; nil for an inline image.
    public let stream: PdfStream?

    /// The inline image; nil for an XObject.
    public let inline: InlineImage?

    /// The image dictionary with full key names (an inline one expanded).
    public let dictionary: PdfDictionary

    public let width: Int
    public let height: Int
    public let isMask: Bool

    /// Maps the unit square the image fills to the space the content started in.
    public let matrix: PdfMatrix

    /// The box of the transformed unit square.
    public let bounds: PdfRect

    public let optionalContent: PdfDictionary?

    public init(_ name: String?, _ stream: PdfStream?, _ inline: InlineImage?, _ dictionary: PdfDictionary, _ width: Int, _ height: Int,
                _ isMask: Bool, _ matrix: PdfMatrix, _ bounds: PdfRect, _ optionalContent: PdfDictionary?) {
        self.name = name
        self.stream = stream
        self.inline = inline
        self.dictionary = dictionary
        self.width = width
        self.height = height
        self.isMask = isMask
        self.matrix = matrix
        self.bounds = bounds
        self.optionalContent = optionalContent
    }
}

/// A shading painted by `sh`.
public struct ShadingInfo {
    public let name: String

    /// The shading dictionary, or the stream of types 4 to 7.
    public let shading: PdfObject

    /// What it covers: the clipping box in force.
    public let bounds: PdfRect

    public init(_ name: String, _ shading: PdfObject, _ bounds: PdfRect) {
        self.name = name
        self.shading = shading
        self.bounds = bounds
    }
}

/// A form XObject or tiling pattern being entered.
public struct FormInfo {
    public let stream: PdfStream
    public let name: String?

    /// Maps form (or pattern) space to the space the content started in.
    public let matrix: PdfMatrix

    /// Its /BBox transformed.
    public let bounds: PdfRect

    public let isPattern: Bool
    public let optionalContent: PdfDictionary?

    public init(_ stream: PdfStream, _ name: String?, _ matrix: PdfMatrix, _ bounds: PdfRect, _ isPattern: Bool, _ optionalContent: PdfDictionary?) {
        self.stream = stream
        self.name = name
        self.matrix = matrix
        self.bounds = bounds
        self.isPattern = isPattern
        self.optionalContent = optionalContent
    }
}

open class ContentVisitor {
    public init() {}

    open func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {}

    open func paintPath(_ context: ContentContext, _ path: PathInfo) {}

    open func paintImage(_ context: ContentContext, _ image: ImageInfo) {}

    open func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {}

    open func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {}

    open func endMarked(_ context: ContentContext, _ marked: MarkedContent) {}

    /// Called before the operations of a form or pattern run; `ContentContext.forms` already ends with it.
    open func beginForm(_ context: ContentContext, _ form: FormInfo) {}

    open func endForm(_ context: ContentContext, _ form: FormInfo) {}
}
