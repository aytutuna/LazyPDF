namespace LazyPDF.Core;

public enum PageObjectKind
{
    Text,
    Image,
    Path,
}

public enum TextAlignment
{
    Left,
    Center,
    Right,
    Justify,
}

/// <summary>
/// Something painted on a page that an editor can select: a block of text, an image or a path.
/// Bounds are in user space. An object is a snapshot; it is stale once the page has been edited
/// and the editor has read it again.
/// </summary>
public abstract class PageObject
{
    internal PageObject(int id, PageObjectKind kind, PdfRect bounds, ContentUnit unit, FormVisit? visit, int sequence)
    {
        Id = id;
        Kind = kind;
        Bounds = bounds;
        Unit = unit;
        Visit = visit;
        Sequence = sequence;
    }

    /// <summary>Position in <see cref="PageEditor.Objects"/>, which runs in painting order.</summary>
    public int Id { get; }

    public PageObjectKind Kind { get; }
    public PdfRect Bounds { get; }

    /// <summary>The form XObjects the object sits in, outermost first; empty for the page itself.</summary>
    public IReadOnlyList<PdfStream> Forms => Visit?.Chain ?? [];

    internal ContentUnit Unit { get; }
    internal FormVisit? Visit { get; }
    internal int Sequence { get; }
}

/// <summary>A line of a text block: its characters in <see cref="TextPage.Chars"/> and the box it covers.</summary>
public sealed record TextObjectLine(int Index, TextRange Range, string Text, PdfRect Bounds);

/// <summary>A paragraph, column piece or table of the page's text, as <see cref="TextPage"/> finds it.</summary>
public sealed class TextObject : PageObject
{
    internal TextObject(int id, PdfRect bounds, ContentUnit unit, FormVisit? visit, int sequence, TextBlock block)
        : base(id, PageObjectKind.Text, bounds, unit, visit, sequence)
    {
        Block = block;
    }

    internal TextBlock Block { get; }
    internal IReadOnlyList<EditGlyph> Glyphs { get; init; } = [];

    /// <summary>Index of the block in <see cref="TextPage.Blocks"/>.</summary>
    public int BlockIndex => Block.Index;

    public IReadOnlyList<TextObjectLine> Lines { get; init; } = [];
    public string Text { get; init; } = "";

    /// <summary>The characters of the block in <see cref="TextPage.Chars"/>.</summary>
    public TextRange Range { get; init; }

    /// <summary>Font, size (user space units), colour and character spacing of the first glyph.</summary>
    public PdfFont? Font { get; init; }
    public double Size { get; init; }
    public RgbColor Color { get; init; }
    public double CharSpacing { get; init; }

    public TextAlignment Alignment { get; init; }

    /// <summary>Distance between the baselines of the first two lines; 0 for a single line.</summary>
    public double LineSpacing { get; init; }

    public bool IsTable => Block.IsTable;
}

public sealed class ImageObject : PageObject
{
    internal ImageObject(int id, PdfRect bounds, ContentUnit unit, FormVisit? visit, int sequence, ImageInfo info, double opacity, int op)
        : base(id, PageObjectKind.Image, bounds, unit, visit, sequence)
    {
        Info = info;
        Opacity = opacity;
        Op = op;
    }

    internal ImageInfo Info { get; }
    internal int Op { get; }

    /// <summary>The resource name; null for an inline image.</summary>
    public string? Name => Info.Name;

    public int Width => Info.Width;
    public int Height => Info.Height;
    public bool IsInline => Info.Inline is not null;
    public bool IsMask => Info.IsMask;

    /// <summary>Maps the unit square the image fills to user space: where it sits, how large and turned.</summary>
    public PdfMatrix Placement => Info.Matrix;

    /// <summary>Fill alpha in force when it is painted.</summary>
    public double Opacity { get; }
}

public sealed class PathObject : PageObject
{
    internal PathObject(int id, PdfRect bounds, ContentUnit unit, FormVisit? visit, int sequence, PathInfo info, PathStyle style, int firstOp, int paintOp)
        : base(id, PageObjectKind.Path, bounds, unit, visit, sequence)
    {
        Info = info;
        Style = style;
        FirstOp = firstOp;
        PaintOp = paintOp;
    }

    internal PathInfo Info { get; }
    internal PathStyle Style { get; }
    internal int FirstOp { get; }
    internal int PaintOp { get; }

    public IReadOnlyList<PathSegment> Segments => Info.Segments;
    public bool Fill => Info.Fill;
    public bool Stroke => Info.Stroke;
    public bool EvenOdd => Info.EvenOdd;

    /// <summary>The path also sets the clip; such a path cannot be moved or changed apart from deleting it.</summary>
    public bool Clips => Info.Clips;

    public RgbColor FillColor => Style.Fill;
    public RgbColor StrokeColor => Style.Stroke;
    public double LineWidth => Style.LineWidth;
    public double Opacity => Style.Opacity;
}

/// <summary>What a path was painted with.</summary>
internal sealed record PathStyle(RgbColor Fill, RgbColor Stroke, double LineWidth, double Opacity, PdfMatrix Ctm);
