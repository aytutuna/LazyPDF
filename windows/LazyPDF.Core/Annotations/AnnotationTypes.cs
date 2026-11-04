namespace LazyPDF.Core;

/// <summary>The annotation subtypes of ISO 32000-1 12.5.6 this layer tells apart; the rest read as <see cref="Other"/>.</summary>
public enum AnnotationType
{
    Other,
    Text,
    Link,
    FreeText,
    Line,
    Square,
    Circle,
    Polygon,
    PolyLine,
    Highlight,
    Underline,
    Squiggly,
    StrikeOut,
    Stamp,
    Caret,
    Ink,
    Popup,
    FileAttachment,
    Redact,
    Widget,
}

/// <summary>The /F bits (ISO 32000-1 12.5.3, table 165).</summary>
[Flags]
public enum AnnotationFlags
{
    None = 0,
    Invisible = 1,
    Hidden = 2,
    Print = 4,
    NoZoom = 8,
    NoRotate = 16,
    NoView = 32,
    ReadOnly = 64,
    Locked = 128,
    ToggleNoView = 256,
    LockedContents = 512,
}

/// <summary>Line ending styles of /LE (ISO 32000-1 12.5.6.7, table 176).</summary>
public enum LineEnding
{
    None,
    Square,
    Circle,
    Diamond,
    OpenArrow,
    ClosedArrow,
    Butt,
    ROpenArrow,
    RClosedArrow,
    Slash,
}

public enum BorderStyle
{
    Solid,
    Dashed,
    Beveled,
    Inset,
    Underline,
}

/// <summary>The states of the review and marked models (ISO 32000-1 12.5.6.3, table 172).</summary>
public enum ReviewStatus
{
    None,
    Accepted,
    Rejected,
    Cancelled,
    Completed,
    Marked,
    Unmarked,
}

/// <summary>Width, style and dash of a border, from /BS or the older /Border.</summary>
public sealed record AnnotationBorder(double Width, BorderStyle Style, IReadOnlyList<double> Dash);

/// <summary>
/// A quadrilateral of a text markup, corners in the order Acrobat writes: top left, top right,
/// bottom left, bottom right (the spec's counter-clockwise order is not what files hold).
/// </summary>
public readonly record struct MarkupQuad(double X1, double Y1, double X2, double Y2, double X3, double Y3, double X4, double Y4)
{
    public static MarkupQuad FromRect(PdfRect r) => new(r.Left, r.Top, r.Right, r.Top, r.Left, r.Bottom, r.Right, r.Bottom);

    public PdfRect Bounds => new(
        Math.Min(Math.Min(X1, X2), Math.Min(X3, X4)), Math.Min(Math.Min(Y1, Y2), Math.Min(Y3, Y4)),
        Math.Max(Math.Max(X1, X2), Math.Max(X3, X4)), Math.Max(Math.Max(Y1, Y2), Math.Max(Y3, Y4)));

    internal double[] ToNumbers() => [X1, Y1, X2, Y2, X3, Y3, X4, Y4];
}

/// <summary>Who wrote an annotation, what it says and when; the caller supplies the date (nothing here reads a clock).</summary>
public sealed record AnnotationInfo(string? Author = null, string? Contents = null, string? Subject = null,
    DateTimeOffset? Date = null, AnnotationFlags Flags = AnnotationFlags.Print);

/// <summary>
/// How an annotation looks. Colours are 1, 3 or 4 numbers (gray, RGB, CMYK) from 0 to 1; a null
/// <see cref="Color"/> takes the colour the kind has by default. <see cref="Cloud"/> is the cloud
/// intensity, 1 or 2 (0 for a plain outline).
/// </summary>
public sealed record AnnotationStyle(double[]? Color = null, double Width = 1, double[]? Dash = null,
    double[]? Fill = null, double Opacity = 1, int Cloud = 0);

/// <summary>The text of a free text annotation: font, colour, alignment and optional XHTML rich text (/RC).</summary>
public sealed record FreeTextStyle(string Family = "Helvetica", double Size = 12, FontStyles Font = FontStyles.Regular,
    double[]? TextColor = null, int Alignment = 0, string? RichText = null);
