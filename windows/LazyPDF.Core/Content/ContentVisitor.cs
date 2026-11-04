namespace LazyPDF.Core;

/// <summary>
/// An open marked-content sequence (ISO 32000-1 14.6): <c>BMC</c> or <c>BDC</c> up to its <c>EMC</c>.
/// </summary>
/// <param name="Tag">The tag, such as <c>Span</c>, <c>OC</c> or <c>Artifact</c>.</param>
/// <param name="Properties">The property dictionary of a <c>BDC</c>, inline or looked up in /Properties; null for <c>BMC</c> or a name that does not resolve.</param>
/// <param name="Mcid">/MCID of the properties, the key into the structure tree.</param>
/// <param name="OptionalContent">For tag <c>OC</c>: the optional content group or membership dictionary the properties name.</param>
public sealed record MarkedContent(string Tag, PdfDictionary? Properties, int? Mcid, PdfDictionary? OptionalContent);

/// <summary>
/// Where a callback comes from and what was true when it came. The object is the interpreter's own
/// and changes with the walk, so a visitor copies what it keeps.
/// </summary>
public sealed class ContentContext
{
    internal ContentContext(PdfDocument document, GraphicsState state, IReadOnlyList<PdfStream> forms, IReadOnlyList<MarkedContent> marked)
    {
        Document = document;
        State = state;
        Forms = forms;
        Marked = marked;
    }

    public PdfDocument Document { get; }

    /// <summary>The graphics state before the operator ran, except for text, where it is the state the glyph is drawn in.</summary>
    public GraphicsState State { get; internal set; }

    /// <summary>
    /// The form XObjects (and tiling patterns) being run, outermost first; empty on the page itself.
    /// With <see cref="OperatorIndex"/> this finds the operation: parse the page's
    /// <see cref="PdfPage.Contents"/>, or <see cref="PdfDocument.Data(PdfStream)"/> of the last form.
    /// </summary>
    public IReadOnlyList<PdfStream> Forms { get; }

    /// <summary>Index of the running operation in the parse of the content stream it belongs to.</summary>
    public int OperatorIndex { get; internal set; }

    public ContentOperation Operation { get; internal set; } = null!;

    /// <summary>Open marked-content sequences, outermost first, those of enclosing streams included.</summary>
    public IReadOnlyList<MarkedContent> Marked { get; }

    /// <summary>The text matrix and text line matrix (9.4.2); identity outside a text object.</summary>
    public PdfMatrix TextMatrix { get; internal set; } = PdfMatrix.Identity;
    public PdfMatrix TextLineMatrix { get; internal set; } = PdfMatrix.Identity;

    /// <summary>The innermost /MCID among the open sequences, or null.</summary>
    public int? Mcid => Marked.LastOrDefault(m => m.Mcid is not null)?.Mcid;

    /// <summary>The innermost optional content dictionary among the open sequences, or null.</summary>
    public PdfDictionary? OptionalContent => Marked.LastOrDefault(m => m.OptionalContent is not null)?.OptionalContent;
}

/// <summary>A glyph shown by <c>Tj</c>, <c>TJ</c>, <c>'</c> or <c>"</c>.</summary>
/// <param name="Character">Code, length, CID, width and Unicode of the character.</param>
/// <param name="Font">The font in force.</param>
/// <param name="Matrix">Maps the em square of the glyph (origin at the glyph origin, one unit the font size) to the space the content started in: the text rendering matrix (9.4.4), with a vertical font's origin shift applied.</param>
/// <param name="Bounds">The box of the glyph's advance by the font's ascent and descent, in that space.</param>
/// <param name="Advance">How far the text matrix moves after the glyph, in text space: along x, or along y for a vertical font. Character and word spacing and horizontal scaling are included.</param>
/// <param name="Element">Index of the string among the operands: 0 for Tj, the array item for TJ, 0 for ' and 1 for ".</param>
/// <param name="Offset">Byte position of the code in that string.</param>
public readonly record struct GlyphInfo(FontChar Character, PdfFont Font, PdfMatrix Matrix, PdfRect Bounds, double Advance, int Element, int Offset)
{
    public int Code => Character.Code;
    public string? Unicode => Character.Unicode;
}

/// <summary>One segment of a path, with the points already transformed by the matrix in force when it was added.</summary>
public readonly record struct PathSegment(PathSegmentKind Kind, double X1, double Y1, double X2, double Y2, double X3, double Y3);

public enum PathSegmentKind
{
    Move,
    Line,
    /// <summary>A cubic Bezier: control points 1 and 2, then the end point.</summary>
    Curve,
    Close,
}

/// <summary>A path painted or turned into a clip.</summary>
/// <param name="Operator">The painting operator: S, s, f, F, f*, B, B*, b, b* or n (a path that only clips).</param>
/// <param name="Segments">The path in the space the content started in.</param>
/// <param name="Bounds">The box of its points, control points of curves included.</param>
/// <param name="InkBounds">The same grown by half the line width when it is stroked.</param>
public sealed record PathInfo(string Operator, IReadOnlyList<PathSegment> Segments, PdfRect Bounds, PdfRect InkBounds, bool Fill, bool Stroke, bool EvenOdd, bool Clips);

/// <summary>An image painted by <c>Do</c> or <c>BI</c>.</summary>
/// <param name="Name">The resource name; null for an inline image.</param>
/// <param name="Stream">The image XObject; null for an inline image.</param>
/// <param name="Inline">The inline image; null for an XObject.</param>
/// <param name="Dictionary">The image dictionary with full key names (an inline one expanded).</param>
/// <param name="Matrix">Maps the unit square the image fills to the space the content started in.</param>
/// <param name="Bounds">The box of the transformed unit square.</param>
public sealed record ImageInfo(string? Name, PdfStream? Stream, InlineImage? Inline, PdfDictionary Dictionary, int Width, int Height,
    bool IsMask, PdfMatrix Matrix, PdfRect Bounds, PdfDictionary? OptionalContent);

/// <summary>A shading painted by <c>sh</c>.</summary>
/// <param name="Shading">The shading dictionary, or the stream of types 4 to 7.</param>
/// <param name="Bounds">What it covers: the clipping box in force.</param>
public sealed record ShadingInfo(string Name, PdfObject Shading, PdfRect Bounds);

/// <summary>A form XObject or tiling pattern being entered.</summary>
/// <param name="Matrix">Maps form (or pattern) space to the space the content started in.</param>
/// <param name="Bounds">Its /BBox transformed.</param>
public sealed record FormInfo(PdfStream Stream, string? Name, PdfMatrix Matrix, PdfRect Bounds, bool IsPattern, PdfDictionary? OptionalContent);

/// <summary>
/// What a <see cref="ContentInterpreter"/> reports. Every method does nothing until overridden;
/// each gets the <see cref="ContentContext"/> that says where it comes from.
/// </summary>
public abstract class ContentVisitor
{
    public virtual void ShowGlyph(ContentContext context, in GlyphInfo glyph) { }

    public virtual void PaintPath(ContentContext context, PathInfo path) { }

    public virtual void PaintImage(ContentContext context, ImageInfo image) { }

    public virtual void PaintShading(ContentContext context, ShadingInfo shading) { }

    public virtual void BeginMarked(ContentContext context, MarkedContent marked) { }

    public virtual void EndMarked(ContentContext context, MarkedContent marked) { }

    /// <summary>Called before the operations of a form or pattern run; <see cref="ContentContext.Forms"/> already ends with it.</summary>
    public virtual void BeginForm(ContentContext context, FormInfo form) { }

    public virtual void EndForm(ContentContext context, FormInfo form) { }
}
