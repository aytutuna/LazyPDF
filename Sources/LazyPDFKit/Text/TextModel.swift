import Foundation

// Twin of windows/LazyPDF.Core/Text/TextModel.cs: what a `TextPage` holds, characters, words, lines and blocks, and
// the options it is built with.

/// A run of characters of a `TextPage` by index: `start` up to, not including, `end`.
public struct TextRange: Equatable {
    public let start: Int
    public let end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }

    // C# int arithmetic wraps; a range from the caller must not trap.
    public var count: Int { max(0, end &- start) }
    public var isEmpty: Bool { end <= start }
}

/// What comes between a line and the one before it in the text.
public enum TextBreak {
    case none

    /// Same row, another cell: a table row, or columns the reader meets one after the other.
    case tab
    case line

    /// A new block: a paragraph, a column, a table.
    case block
}

/// One shown glyph, or a space the gap between two glyphs implies. A ligature is one glyph with several characters in
/// `text`.
public final class TextChar {
    init(index: Int, text: String, quad: TextQuad, font: PdfFont?, size: Double, color: RgbColor, renderMode: Int, operatorIndex: Int,
         form: PdfStream?, element: Int, offset: Int, mcid: Int?, isArtifact: Bool, isSpace: Bool, isImplied: Bool, isRtl: Bool, line: Int) {
        self.index = index
        self.text = text
        self.quad = quad
        self.font = font
        self.size = size
        self.color = color
        self.renderMode = renderMode
        self.operatorIndex = operatorIndex
        self.form = form
        self.element = element
        self.offset = offset
        self.mcid = mcid
        self.isArtifact = isArtifact
        self.isSpace = isSpace
        self.isImplied = isImplied
        self.isRtl = isRtl
        self.line = line
    }

    /// Position in `TextPage.chars`, the reading order (logical order within a right-to-left run).
    public internal(set) var index: Int

    /// Unicode text; empty for a glyph the font gives no text for. Arabic presentation forms and Latin ligature code
    /// points are folded to the plain letters.
    public let text: String

    public internal(set) var quad: TextQuad

    /// Nil for an implied space.
    public let font: PdfFont?

    /// The font size as drawn, in user space units (text matrix and CTM included).
    public let size: Double

    /// Fill colour; stroke colour for render mode 1.
    public let color: RgbColor

    public let renderMode: Int

    /// Index of the operation in the parse of the content stream it belongs to (the page's, or `form`'s); -1 for an
    /// implied space.
    public let operatorIndex: Int

    /// The innermost form XObject the glyph came from, nil on the page itself.
    public let form: PdfStream?

    /// Operand index and byte position of the code, as in `GlyphInfo`.
    public let element: Int
    public let offset: Int

    public let mcid: Int?
    public let isArtifact: Bool

    /// A space glyph, a space between words implied by a gap, or another white space character.
    public let isSpace: Bool
    public let isImplied: Bool

    /// The glyph sits in a right-to-left run.
    public internal(set) var isRtl: Bool

    /// Index in `TextPage.words`; -1 for a space.
    public internal(set) var word = -1
    public internal(set) var line: Int
}

public struct TextWord {
    public let index: Int
    public let range: TextRange
    public let text: String
    public let bounds: PdfRect
    public let line: Int
}

/// A row of characters on one baseline with no wide gap in it; a table cell is one line. `quad` is the box of the
/// whole line in the frame of its first glyph, `before` what separates it from the previous line in text.
/// `isVertical`: the line runs top to bottom (a vertical writing font).
public struct PageLine {
    public let index: Int
    public let range: TextRange
    public let text: String
    public let bounds: PdfRect
    public let quad: TextQuad
    public let block: Int
    public let before: TextBreak
    public let isVertical: Bool
    public let isRtl: Bool
}

/// A paragraph, column piece or table.
public struct TextBlock {
    public let index: Int
    public let lines: TextRange
    public let bounds: PdfRect
    public let isTable: Bool
}

/// What the text of a page is built from. `includeArtifacts` keeps text marked /Artifact (headers, footers, page
/// numbers); `removeDuplicates` drops a glyph drawn again at nearly the same place, how bold is faked;
/// `includeAnnotations` adds the text of the appearances of annotations and form fields that are shown, placed on the
/// page. Those characters have `TextChar.form` set to the appearance stream, which the page's own content does not
/// reach.
public struct TextPageOptions {
    public var includeArtifacts: Bool
    public var removeDuplicates: Bool
    public var includeAnnotations: Bool

    public init(includeArtifacts: Bool = true, removeDuplicates: Bool = true, includeAnnotations: Bool = false) {
        self.includeArtifacts = includeArtifacts
        self.removeDuplicates = removeDuplicates
        self.includeAnnotations = includeAnnotations
    }
}

/// The nearest character to a point, with the word and line it is in.
public struct TextHit: Equatable {
    public let char: Int
    public let word: Int
    public let line: Int
    public let distance: Double
}
