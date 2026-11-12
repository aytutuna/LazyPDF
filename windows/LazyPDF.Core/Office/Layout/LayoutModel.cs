namespace LazyPDF.Core.Office;

/// <summary>A PDF made from an Office file: its bytes, page count, what was left out and the code points no font could draw.</summary>
public sealed record OfficePdf(byte[] Bytes, int Pages, IReadOnlyList<SkippedFeature> Skipped, IReadOnlyList<int> Missing);

/// <summary>Something in the source the converter did not carry over: a stable <paramref name="Kind"/> code and how many times it occurred.</summary>
public sealed record SkippedFeature(string Kind, int Count);

internal static class SkippedKinds
{
    public const string RightToLeftText = "rtl-text";
    public const string ComplexScript = "complex-script";
    public const string UnreadablePicture = "picture";
}

internal enum LayoutAlign { Left, Center, Right, Justify }

internal enum LineRule { Multiple, Exact, AtLeast }

internal enum LayoutField { None, PageNumber, PageCount }

/// <summary>Text in one style. In a header or footer a field run is replaced by the page number or the page count.</summary>
internal sealed class LayoutRun
{
    public string Text { get; init; } = "";
    public string Family { get; init; } = OfficeFontSource.DefaultFamily;
    public double Size { get; init; } = 11;
    public bool Bold { get; init; }
    public bool Italic { get; init; }
    public bool Underline { get; init; }
    public bool Strike { get; init; }
    /// <summary>0xRRGGBB.</summary>
    public int Color { get; init; }
    public int? Highlight { get; init; }
    /// <summary>Points above the baseline; negative sinks the text. The size is already the reduced one.</summary>
    public double Shift { get; init; }
    public LayoutField Field { get; init; }
    /// <summary>A picture in line with the text; then the text is empty and the font only sets the descent of the line.</summary>
    public LayoutPicture? Picture { get; init; }
}

/// <summary>A picture file as the document holds it and the size it takes on the page, in points. The crop edges are the fractions of the picture cut off on each side.</summary>
internal sealed record LayoutPicture(byte[] Data, double Width, double Height, double CropLeft = 0, double CropTop = 0, double CropRight = 0, double CropBottom = 0);

internal abstract class LayoutBlock;

internal sealed class LayoutPageBreak : LayoutBlock;

/// <summary>A paragraph. Text may hold \n for a line break and \t for a tab.</summary>
internal sealed class LayoutParagraph : LayoutBlock
{
    public List<LayoutRun> Runs { get; init; } = [];
    public LayoutAlign Align { get; init; }
    public double Left { get; init; }
    public double Right { get; init; }
    /// <summary>Added to Left for the first line; negative hangs it.</summary>
    public double FirstLine { get; init; }
    public double Before { get; init; }
    public double After { get; init; }
    /// <summary>A factor for <see cref="LineRule.Multiple"/>, else points.</summary>
    public double LineSpacing { get; init; } = 1;
    public LineRule Rule { get; init; }
    public bool KeepWithNext { get; init; }
    public bool PageBreakBefore { get; init; }
    public bool WidowControl { get; init; } = true;
    /// <summary>A tab stop, from the text area, for the tab after a list number; that tab is the first one of the paragraph.</summary>
    public double? LabelTab { get; init; }
}

/// <summary>A line of a cell edge: its thickness in points and 0xRRGGBB.</summary>
internal sealed record LayoutBorder(double Width, int Color);

internal enum LayoutVAlign { Top, Center, Bottom }

/// <summary>
/// A cell, placed on the table's grid. <see cref="RowSpan"/> counts the rows a vertical merge covers; the cells that continue
/// it are not kept. The borders are the ones left after the two cells at an edge have been compared.
/// </summary>
internal sealed class LayoutCell
{
    public int Column { get; init; }
    public int Span { get; init; } = 1;
    public int RowSpan { get; set; } = 1;
    public List<LayoutParagraph> Paragraphs { get; init; } = [];
    public int? Fill { get; init; }
    public LayoutBorder? Top { get; set; }
    public LayoutBorder? Right { get; set; }
    public LayoutBorder? Bottom { get; set; }
    public LayoutBorder? Left { get; set; }
    public double MarginTop { get; init; }
    public double MarginRight { get; init; } = 5.4;
    public double MarginBottom { get; init; }
    public double MarginLeft { get; init; } = 5.4;
    public LayoutVAlign VAlign { get; init; }
}

internal sealed class LayoutRow
{
    public List<LayoutCell> Cells { get; init; } = [];
    /// <summary>Repeated at the top of every page the table continues on.</summary>
    public bool Header { get; init; }
    public bool CantSplit { get; init; }
    public double Height { get; init; }
    /// <summary>The height is fixed and what does not fit in it is not drawn; else it is a minimum.</summary>
    public bool HeightExact { get; init; }
}

/// <summary>A table. A column of 0 has no width of its own and shares what the others leave.</summary>
internal sealed class LayoutTable : LayoutBlock
{
    public List<double> Columns { get; init; } = [];
    /// <summary>From the left of the text area, for a left aligned table.</summary>
    public double Indent { get; init; }
    public LayoutAlign Align { get; init; }
    public List<LayoutRow> Rows { get; init; } = [];
}

/// <summary>Sizes in points. Header and footer distances are measured from the page edge to the band.</summary>
internal sealed class LayoutGeometry
{
    public double Width { get; init; } = 595.28;
    public double Height { get; init; } = 841.89;
    public double Top { get; init; } = 72;
    public double Right { get; init; } = 72;
    public double Bottom { get; init; } = 72;
    public double Left { get; init; } = 72;
    public double HeaderDistance { get; init; } = 36;
    public double FooterDistance { get; init; } = 36;
}

internal enum PageVariant { Default, First, Even }

/// <summary>A run of pages with one geometry and one header and footer; it always starts on a new page.</summary>
internal sealed class LayoutSection
{
    public LayoutGeometry Page { get; set; } = new();
    public List<LayoutParagraph> Header { get; init; } = [];
    public List<LayoutParagraph> Footer { get; init; } = [];
    /// <summary>The first page of the section has its own bands.</summary>
    public bool TitlePage { get; init; }
    /// <summary>Even pages, counted from the start of the document, have their own bands.</summary>
    public bool EvenAndOdd { get; init; }
    public List<LayoutParagraph> FirstHeader { get; init; } = [];
    public List<LayoutParagraph> FirstFooter { get; init; } = [];
    public List<LayoutParagraph> EvenHeader { get; init; } = [];
    public List<LayoutParagraph> EvenFooter { get; init; } = [];
    public List<LayoutBlock> Blocks { get; init; } = [];

    public List<LayoutParagraph> HeaderOf(PageVariant variant) => variant switch { PageVariant.First => FirstHeader, PageVariant.Even => EvenHeader, _ => Header };

    public List<LayoutParagraph> FooterOf(PageVariant variant) => variant switch { PageVariant.First => FirstFooter, PageVariant.Even => EvenFooter, _ => Footer };
}

internal sealed class LayoutDocument
{
    public List<LayoutSection> Sections { get; init; } = [];
    /// <summary>What the format reader left out; the layout adds its own to these.</summary>
    public List<SkippedFeature> Skipped { get; init; } = [];
}

/// <summary>Positions are in points from the top left of the page.</summary>
internal abstract record LayoutBox;

/// <summary>A piece of one line in one style. <see cref="SpaceExtra"/> is added after every space (justified lines).</summary>
internal sealed record PlacedText(double X, double Baseline, string Text, string Family, FontStyles Style, double Size, int Color, double SpaceExtra) : LayoutBox;

/// <summary>A picture with its top left corner at X, Y.</summary>
internal sealed record PlacedImage(double X, double Y, double Width, double Height, LayoutPicture Source) : LayoutBox;

internal sealed record PlacedRect(double X, double Y, double Width, double Height, int Color) : LayoutBox;

internal sealed record LayoutPage(double Width, double Height, IReadOnlyList<LayoutBox> Boxes);

internal sealed record LayoutResult(IReadOnlyList<LayoutPage> Pages, IReadOnlyList<SkippedFeature> Skipped, IReadOnlyList<int> Missing);
