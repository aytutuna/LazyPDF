namespace LazyPDF.Core.Office;

/// <summary>What a presentation may hold. Too many slides, too many shapes drawn in all or too much text in all is refused; the rest is cut and noted.</summary>
internal sealed record PptxLimits(
    int MaxSlides = 1000,
    int MaxShapes = 5000,
    int MaxParagraphs = 5000,
    int MaxTextLength = 100_000,
    long MaxTotalText = 4_000_000,
    long MaxDrawnShapes = 200_000,
    int MaxGroupDepth = 5,
    int MaxPictures = 2000,
    int MaxTableRows = 500,
    int MaxTableColumns = 64)
{
    public const double MinSide = 36;
    public const double MaxSide = 14_400;
    public static readonly PptxLimits Default = new();
}

internal static class PptxSkipped
{
    public const string HiddenSlide = "hidden-slide";
    public const string Shape = "slide-shape";
    public const string Gradient = "slide-gradient";
    public const string TextCut = "slide-text-cut";
    public const string TextRotation = "text-rotation";
    public const string CustomGeometry = "slide-custom-geometry";
    public const string Effect = "slide-effect";
    public const string Chart = "slide-chart";
    public const string SmartArt = "slide-smartart";
    public const string Media = "slide-media";
    public const string EmbeddedObject = "slide-object";
    public const string TableStyle = "slide-table-style";
}

/// <summary>What fills the page behind a slide: a color, a picture stretched over it, or nothing.</summary>
internal sealed record PptxBackground(int? Color, LayoutPicture? Picture);

/// <summary>The text of a shape: the room inside it and its paragraphs, already resolved against the master, layout and autofit.</summary>
internal sealed class PptxBody
{
    public double Left { get; init; }
    public double Top { get; init; }
    public double Right { get; init; }
    public double Bottom { get; init; }
    public LayoutVAlign Anchor { get; init; }
    public bool Wrap { get; init; } = true;
    public List<LayoutParagraph> Paragraphs { get; init; } = [];
}

/// <summary>A table with its top left corner at X, Y in points; the column widths and the minimum row heights are those of the file.</summary>
internal sealed record PptxTable(double X, double Y, LayoutTable Table);

/// <summary>
/// A shape in points from the top left of the slide. A slide number field in the text is a <see cref="LayoutField.PageNumber"/> run.
/// The frame is where the text goes, turned back upright. <see cref="Fill"/> is a plain rectangle of the frame; any other
/// outline, with its arrowheads, is in <see cref="Paths"/>, already placed on the slide.
/// </summary>
internal sealed class PptxShape
{
    public double X { get; init; }
    public double Y { get; init; }
    public double Width { get; init; }
    public double Height { get; init; }
    public int? Fill { get; init; }
    public List<PlacedPath> Paths { get; init; } = [];
    public PlacedImage? Picture { get; init; }
    public PptxTable? Table { get; init; }
    public PptxBody? Body { get; init; }
}

internal sealed class PptxSlide
{
    public int Number { get; init; }
    public PptxBackground? Background { get; init; }
    /// <summary>Bottom to top: the master's shapes, the layout's, then the slide's own.</summary>
    public List<PptxShape> Shapes { get; init; } = [];
}

internal sealed class PptxPresentation
{
    public double Width { get; init; }
    public double Height { get; init; }
    public List<PptxSlide> Slides { get; init; } = [];
    public List<SkippedFeature> Skipped { get; init; } = [];
}
