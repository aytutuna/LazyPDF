namespace LazyPDF.Core.Office;

/// <summary>What a workbook may hold; a file over a limit is refused with a <see cref="PdfReadException"/>, except text, which is cut.</summary>
internal sealed record XlsxLimits(
    int MaxSheets = 256,
    int MaxCells = 1_000_000,
    int MaxMergedRanges = 100_000,
    int MaxSharedStrings = 500_000,
    int MaxStyles = 64_000,
    int MaxNumberFormats = 2000,
    int MaxDefinedNames = 10_000,
    int MaxTextLength = 32_767,
    long MaxTotalText = 16_000_000)
{
    public const int MaxRow = 1_048_576;
    public const int MaxColumn = 16_384;
    public const int MaxFormatLength = 255;
    public static readonly XlsxLimits Default = new();
}

internal static class XlsxSkipped
{
    public const string HiddenSheet = "hidden-sheet";
    public const string ChartSheet = "chart-sheet";
    public const string OtherSheet = "other-sheet";
    public const string RichText = "rich-text";
    public const string FillPattern = "fill-pattern";
    public const string TextRotation = "text-rotation";
    public const string FormulaWithoutValue = "formula-no-value";
    public const string CellOutsideGrid = "cell-outside-grid";
    public const string LongText = "long-text";
}

internal enum XlsxHorizontal { General, Left, Center, Right, Fill, Justify, CenterContinuous, Distributed }

internal enum XlsxVertical { Top, Center, Bottom, Justify, Distributed }

internal enum XlsxCellKind { Blank, Number, Text, Bool, Error }

/// <summary>A font as the styles part states it. <see cref="Color"/> is 0xRRGGBB, or null for the automatic colour.</summary>
internal sealed record XlsxFont(string Name, double Size, bool Bold, bool Italic, bool Underline, bool Strike, int? Color);

/// <summary>A fill: the colour of a solid fill (null for none); <see cref="Unsupported"/> when the file asks for a pattern or gradient, which is left out.</summary>
internal sealed record XlsxFill(int? Color, bool Unsupported);

/// <summary>One side of a border: the style name as the file writes it (thin, medium, dashed, ...) and the colour, null for automatic.</summary>
internal sealed record XlsxBorderEdge(string Style, int? Color);

internal sealed record XlsxBorder(XlsxBorderEdge? Left, XlsxBorderEdge? Right, XlsxBorderEdge? Top, XlsxBorderEdge? Bottom);

/// <summary>A cell format (a cellXfs entry): the indexes into the font, fill and border lists and the alignment. Rotated text is not drawn rotated.</summary>
internal sealed record XlsxXf(
    int Font, int Fill, int Border, int NumberFormatId, XlsxHorizontal Horizontal, XlsxVertical Vertical, bool Wrap, int Indent, bool Rotated);

/// <summary>
/// A cell with its text already formatted. <see cref="Color"/> is the colour the number format asked for. <see cref="RichFont"/> is
/// the font of the first run of a rich text cell, which replaces the font of the format.
/// </summary>
internal sealed class XlsxCell
{
    public int Column { get; init; }
    public int Style { get; init; }
    public XlsxCellKind Kind { get; init; }
    public string Text { get; init; } = "";
    public int? Color { get; init; }
    public XlsxFont? RichFont { get; init; }
}

internal sealed class XlsxRow
{
    public int Index { get; init; }
    /// <summary>Points, when the row states a height; null leaves it to the content.</summary>
    public double? Height { get; set; }
    public bool Hidden { get; set; }
    public List<XlsxCell> Cells { get; } = [];
}

/// <summary>A run of columns <see cref="First"/> to <see cref="Last"/> (1-based) that share a width in points.</summary>
internal sealed record XlsxColumns(int First, int Last, double Width, bool Hidden);

/// <summary>A block of cells, 1-based and inclusive.</summary>
internal readonly record struct XlsxRange(int FirstRow, int FirstColumn, int LastRow, int LastColumn);

internal sealed class XlsxSheet
{
    public string Name { get; init; } = "";
    public List<XlsxRow> Rows { get; } = [];
    public List<XlsxColumns> Columns { get; } = [];
    public double DefaultColumnWidth { get; set; }
    public double DefaultRowHeight { get; set; } = 15;
    public List<XlsxRange> Merges { get; } = [];
    public List<XlsxRange> PrintArea { get; } = [];
    /// <summary>The rows (first, last) and columns repeated on every page, null for none.</summary>
    public (int First, int Last)? TitleRows { get; set; }
    public (int First, int Last)? TitleColumns { get; set; }

    public double WidthOf(int column)
    {
        foreach (var c in Columns)
        {
            if (column >= c.First && column <= c.Last) return c.Width;
        }
        return DefaultColumnWidth;
    }

    public bool IsColumnHidden(int column) => Columns.Any(c => column >= c.First && column <= c.Last && c.Hidden);
}

internal sealed class XlsxStyles
{
    public List<XlsxFont> Fonts { get; } = [];
    public List<XlsxFill> Fills { get; } = [];
    public List<XlsxBorder> Borders { get; } = [];
    public List<XlsxXf> Xfs { get; } = [];
    /// <summary>Width in pixels of the widest digit of the default font, which column widths are counted in.</summary>
    public int MaxDigitWidth { get; set; } = 7;
    public Dictionary<int, string> Codes { get; } = [];
    private readonly Dictionary<string, NumberFormat> _parsed = [];

    public XlsxXf Xf(int index) => index >= 0 && index < Xfs.Count ? Xfs[index] : Xfs[0];

    public NumberFormat Format(int numberFormatId)
    {
        string? code = Codes.GetValueOrDefault(numberFormatId) ?? NumberFormat.BuiltInCode(numberFormatId);
        if (code is null || code.Length > XlsxLimits.MaxFormatLength) return NumberFormat.General;
        if (!_parsed.TryGetValue(code, out var format)) _parsed[code] = format = NumberFormat.Parse(code);
        return format;
    }
}

internal sealed class XlsxWorkbook
{
    public bool Date1904 { get; init; }
    public XlsxStyles Styles { get; init; } = new();
    public List<XlsxSheet> Sheets { get; } = [];
    public List<SkippedFeature> Skipped { get; } = [];
}
