using System.Globalization;

namespace LazyPDF.Core;

public readonly record struct StampColor(double R, double G, double B)
{
    public static StampColor Black => new(0, 0, 0);

    public static StampColor Gray(double level) => new(level, level, level);
}

public enum StampAnchor
{
    TopLeft, Top, TopRight,
    Left, Center, Right,
    BottomLeft, Bottom, BottomRight,
}

public enum BackgroundFit
{
    /// <summary>Covers the page, the overflow is clipped.</summary>
    Cover,
    /// <summary>Fits inside the page.</summary>
    Contain,
    /// <summary>Fills the page, the proportions give way.</summary>
    Stretch,
}

public enum StampKind
{
    Watermark,
    Background,
    HeaderFooter,
    Bates,
}

/// <summary>
/// A text or image laid over or under the page. Sizes and offsets are display points of the page as
/// shown (rotation applied, y down); <see cref="Pages"/> are 0-based indices, null for every page.
/// </summary>
public sealed record WatermarkSpec
{
    /// <summary>The text, lines separated by <c>\n</c>. Set this or <see cref="Image"/>.</summary>
    public string? Text { get; init; }
    public PdfImage? Image { get; init; }
    public string FontFamily { get; init; } = "Helvetica";
    public FontStyles FontStyle { get; init; } = FontStyles.Bold;
    public StampColor Color { get; init; } = StampColor.Gray(0.5);
    public double Opacity { get; init; } = 0.3;
    /// <summary>Degrees counter-clockwise as seen, about the centre of the watermark.</summary>
    public double Rotation { get; init; }
    /// <summary>The width of the watermark, unrotated, as a fraction of the page width.</summary>
    public double Scale { get; init; } = 0.6;
    public StampAnchor Anchor { get; init; } = StampAnchor.Center;
    /// <summary>Moves it right and down from the anchor.</summary>
    public double OffsetX { get; init; }
    public double OffsetY { get; init; }
    public bool Behind { get; init; }
    /// <summary>When set, the watermark is optional content under this name, so a viewer can switch it off.</summary>
    public string? LayerName { get; init; }
    public IReadOnlyList<int>? Pages { get; init; }
}

/// <summary>A colour, an image or both behind the page content.</summary>
public sealed record BackgroundSpec
{
    public StampColor? Color { get; init; }
    public PdfImage? Image { get; init; }
    public BackgroundFit Fit { get; init; } = BackgroundFit.Cover;
    public double Opacity { get; init; } = 1;
    public string? LayerName { get; init; }
    public IReadOnlyList<int>? Pages { get; init; }
}

/// <summary>
/// Bates numbers (a running number with a prefix and suffix) for the pages of a batch of documents.
/// The number of the first page stamped is <see cref="Start"/>.
/// </summary>
public sealed record BatesSpec(string Prefix = "", string Suffix = "", int Digits = 6, long Start = 1)
{
    public string Format(long number) =>
        Prefix + number.ToString("D" + Math.Clamp(Digits, 1, 18), CultureInfo.InvariantCulture) + Suffix;
}

/// <summary>
/// The three slots of a header or a footer. Text may hold <c>{page}</c>, <c>{pages}</c>,
/// <c>{date}</c> or <c>{date:format}</c>, <c>{file}</c> and <c>{bates}</c>; anything else, a
/// brace included, stays as typed.
/// </summary>
public sealed record HeaderFooterBand(string Left = "", string Center = "", string Right = "");

public sealed record HeaderFooterSpec
{
    public HeaderFooterBand Header { get; init; } = new();
    public HeaderFooterBand Footer { get; init; } = new();
    /// <summary>Used on even pages (the 2nd, 4th...) in place of the header; null means the same as <see cref="Header"/>.</summary>
    public HeaderFooterBand? EvenHeader { get; init; }
    public HeaderFooterBand? EvenFooter { get; init; }
    public string FontFamily { get; init; } = "Helvetica";
    public FontStyles FontStyle { get; init; }
    public double FontSize { get; init; } = 10;
    public StampColor Color { get; init; } = StampColor.Black;
    public double MarginX { get; init; } = 36;
    public double MarginTop { get; init; } = 36;
    public double MarginBottom { get; init; } = 36;
    /// <summary>The number <c>{page}</c> shows on the first page of the document.</summary>
    public int StartNumber { get; init; } = 1;
    /// <summary>The date <c>{date}</c> shows; Core has no clock, the app passes it in.</summary>
    public DateTimeOffset Date { get; init; }
    public string DateFormat { get; init; } = "yyyy-MM-dd";
    public CultureInfo Culture { get; init; } = CultureInfo.InvariantCulture;
    /// <summary>What <c>{file}</c> shows.</summary>
    public string FileName { get; init; } = "";
    /// <summary>What <c>{bates}</c> shows; the stamped pages are numbered in document order.</summary>
    public BatesSpec? Bates { get; init; }
    public IReadOnlyList<int>? Pages { get; init; }
}

/// <summary>What one stamp run did. <see cref="NextBates"/> is where the next document of a batch starts, 0 without Bates numbers.</summary>
public sealed record StampRun(int Id, int Pages, long NextBates, IReadOnlyList<int> Missing);

/// <summary>A run found in the file. <see cref="Pages"/> are the 0-based pages carrying it.</summary>
public sealed record StampInfo(int Id, StampKind Kind, string? Label, bool Behind, IReadOnlyList<int> Pages);
