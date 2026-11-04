namespace LazyPDF.Core;

/// <summary>A run of characters of a <see cref="TextPage"/> by index: <see cref="Start"/> up to, not including, <see cref="End"/>.</summary>
public readonly record struct TextRange(int Start, int End)
{
    public int Count => Math.Max(0, End - Start);
    public bool IsEmpty => End <= Start;
}

/// <summary>What comes between a line and the one before it in the text.</summary>
public enum TextBreak
{
    None,

    /// <summary>Same row, another cell: a table row, or columns the reader meets one after the other.</summary>
    Tab,
    Line,

    /// <summary>A new block: a paragraph, a column, a table.</summary>
    Block,
}

/// <summary>
/// One shown glyph, or a space the gap between two glyphs implies. A ligature is one glyph with
/// several characters in <see cref="Text"/>.
/// </summary>
public sealed class TextChar
{
    internal TextChar()
    {
    }

    /// <summary>Position in <see cref="TextPage.Chars"/>, the reading order (logical order within a right-to-left run).</summary>
    public int Index { get; internal set; }

    /// <summary>Unicode text; empty for a glyph the font gives no text for. Arabic presentation forms and Latin ligature code points are folded to the plain letters.</summary>
    public string Text { get; internal init; } = "";

    public TextQuad Quad { get; internal set; }

    /// <summary>Null for an implied space.</summary>
    public PdfFont? Font { get; internal init; }

    /// <summary>The font size as drawn, in user space units (text matrix and CTM included).</summary>
    public double Size { get; internal init; }

    /// <summary>Fill colour; stroke colour for render mode 1.</summary>
    public RgbColor Color { get; internal init; }

    public int RenderMode { get; internal init; }

    /// <summary>Index of the operation in the parse of the content stream it belongs to (the page's, or <see cref="Form"/>'s); -1 for an implied space.</summary>
    public int OperatorIndex { get; internal init; } = -1;

    /// <summary>The innermost form XObject the glyph came from, null on the page itself.</summary>
    public PdfStream? Form { get; internal init; }

    /// <summary>Operand index and byte position of the code, as in <see cref="GlyphInfo"/>.</summary>
    public int Element { get; internal init; }
    public int Offset { get; internal init; }

    public int? Mcid { get; internal init; }
    public bool IsArtifact { get; internal init; }

    /// <summary>A space glyph, a space between words implied by a gap, or another white space character.</summary>
    public bool IsSpace { get; internal init; }
    public bool IsImplied { get; internal init; }

    /// <summary>The glyph sits in a right-to-left run.</summary>
    public bool IsRtl { get; internal set; }

    /// <summary>Index in <see cref="TextPage.Words"/>; -1 for a space.</summary>
    public int Word { get; internal set; } = -1;
    public int Line { get; internal set; }
}

public sealed record TextWord(int Index, TextRange Range, string Text, PdfRect Bounds, int Line);

/// <summary>A row of characters on one baseline with no wide gap in it; a table cell is one line.</summary>
/// <param name="Quad">The box of the whole line in the frame of its first glyph.</param>
/// <param name="Before">What separates it from the previous line in text.</param>
/// <param name="IsVertical">The line runs top to bottom (a vertical writing font).</param>
public sealed record PageLine(int Index, TextRange Range, string Text, PdfRect Bounds, TextQuad Quad, int Block, TextBreak Before, bool IsVertical, bool IsRtl);

/// <summary>A paragraph, column piece or table.</summary>
public sealed record TextBlock(int Index, TextRange Lines, PdfRect Bounds, bool IsTable);

/// <summary>What the text of a page is built from.</summary>
/// <param name="IncludeArtifacts">Keep text marked /Artifact (headers, footers, page numbers).</param>
/// <param name="RemoveDuplicates">Drop a glyph drawn again at nearly the same place, how bold is faked.</param>
public sealed record TextPageOptions(bool IncludeArtifacts = true, bool RemoveDuplicates = true);

/// <summary>The nearest character to a point, with the word and line it is in.</summary>
public readonly record struct TextHit(int Char, int Word, int Line, double Distance);
