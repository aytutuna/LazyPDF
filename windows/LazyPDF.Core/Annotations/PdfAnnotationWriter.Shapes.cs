namespace LazyPDF.Core;

public sealed partial class PdfAnnotationWriter
{
    /// <summary>
    /// A Highlight, Underline, StrikeOut or Squiggly over the quads the caller found for the text.
    /// The default colour is yellow for a highlight and red for the rest.
    /// </summary>
    public PdfAnnotation AddTextMarkup(PdfPage page, AnnotationType kind, IReadOnlyList<MarkupQuad> quads, AnnotationInfo? info = null, AnnotationStyle? style = null)
    {
        if (kind is not (AnnotationType.Highlight or AnnotationType.Underline or AnnotationType.StrikeOut or AnnotationType.Squiggly))
            throw new ArgumentException("Not a text markup kind.", nameof(kind));
        if (quads.Count == 0) throw new ArgumentException("A text markup needs at least one quad.", nameof(quads));
        style ??= new AnnotationStyle();
        var bounds = quads.Select(q => q.Bounds).Aggregate((a, b) => new PdfRect(Math.Min(a.Left, b.Left), Math.Min(a.Bottom, b.Bottom), Math.Max(a.Right, b.Right), Math.Max(a.Top, b.Top)));
        var d = NewAnnotation(kind.ToString(), Inflate(bounds, 1), info, style.Color ?? (kind == AnnotationType.Highlight ? AppearanceBuilder.Yellow : AppearanceBuilder.Red), style.Opacity);
        d["QuadPoints"] = Numbers(quads.SelectMany(q => q.ToNumbers()));
        return Place(page, d);
    }

    public PdfAnnotation AddSquare(PdfPage page, PdfRect rect, AnnotationStyle? style = null, AnnotationInfo? info = null) =>
        AddBox(page, "Square", rect, style, info);

    public PdfAnnotation AddCircle(PdfPage page, PdfRect rect, AnnotationStyle? style = null, AnnotationInfo? info = null) =>
        AddBox(page, "Circle", rect, style, info);

    private PdfAnnotation AddBox(PdfPage page, string subtype, PdfRect rect, AnnotationStyle? style, AnnotationInfo? info)
    {
        style ??= new AnnotationStyle();
        var d = NewAnnotation(subtype, rect, info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        Decorate(d, style);
        if (style.Cloud > 0)
        {
            double inset = CloudBorder.Bulge(style.Cloud) + style.Width / 2;
            d["RD"] = Numbers([inset, inset, inset, inset]);
        }
        return Place(page, d);
    }

    private static void Decorate(PdfDictionary d, AnnotationStyle style)
    {
        SetBorder(d, style);
        if (style.Fill is not null) d["IC"] = Numbers(style.Fill);
        if (style.Cloud > 0)
        {
            d["BE"] = new PdfDictionary { ["S"] = new PdfName("C"), ["I"] = new PdfNumber(Math.Clamp(style.Cloud, 1, 2)) };
        }
    }

    public PdfAnnotation AddLine(PdfPage page, (double X, double Y) from, (double X, double Y) to, AnnotationStyle? style = null, AnnotationInfo? info = null,
        LineEnding start = LineEnding.None, LineEnding end = LineEnding.None)
    {
        style ??= new AnnotationStyle();
        double margin = Margin(style, start != LineEnding.None || end != LineEnding.None);
        var d = NewAnnotation("Line", Inflate(BoundsOf([from, to]), margin), info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        d["L"] = Numbers([from.X, from.Y, to.X, to.Y]);
        d["LE"] = Endings(start, end);
        Decorate(d, style);
        return Place(page, d);
    }

    /// <summary>A line with an open arrow head at <paramref name="to"/>, marked /IT /LineArrow as Acrobat's arrow tool does.</summary>
    public PdfAnnotation AddArrow(PdfPage page, (double X, double Y) from, (double X, double Y) to, AnnotationStyle? style = null, AnnotationInfo? info = null)
    {
        style ??= new AnnotationStyle();
        double margin = Margin(style, true);
        var d = NewAnnotation("Line", Inflate(BoundsOf([from, to]), margin), info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        d["L"] = Numbers([from.X, from.Y, to.X, to.Y]);
        d["LE"] = Endings(LineEnding.None, LineEnding.OpenArrow);
        d["IT"] = new PdfName("LineArrow");
        Decorate(d, style);
        return Place(page, d);
    }

    public PdfAnnotation AddPolyLine(PdfPage page, IReadOnlyList<(double X, double Y)> points, AnnotationStyle? style = null, AnnotationInfo? info = null,
        LineEnding start = LineEnding.None, LineEnding end = LineEnding.None)
    {
        if (points.Count < 2) throw new ArgumentException("A polyline needs two points.", nameof(points));
        style ??= new AnnotationStyle();
        double margin = Margin(style, start != LineEnding.None || end != LineEnding.None);
        var d = NewAnnotation("PolyLine", Inflate(BoundsOf(points), margin), info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        d["Vertices"] = Numbers(points.SelectMany(p => new[] { p.X, p.Y }));
        d["LE"] = Endings(start, end);
        Decorate(d, style);
        return Place(page, d);
    }

    public PdfAnnotation AddPolygon(PdfPage page, IReadOnlyList<(double X, double Y)> points, AnnotationStyle? style = null, AnnotationInfo? info = null) =>
        AddClosed(page, points, style ?? new AnnotationStyle(), info, intent: null);

    /// <summary>A polygon with a cloud border (/IT /PolygonCloud); the style's cloud intensity is 1 when it has none.</summary>
    public PdfAnnotation AddCloud(PdfPage page, IReadOnlyList<(double X, double Y)> points, AnnotationStyle? style = null, AnnotationInfo? info = null)
    {
        style ??= new AnnotationStyle();
        return AddClosed(page, points, style.Cloud > 0 ? style : style with { Cloud = 1 }, info, "PolygonCloud");
    }

    private PdfAnnotation AddClosed(PdfPage page, IReadOnlyList<(double X, double Y)> points, AnnotationStyle style, AnnotationInfo? info, string? intent)
    {
        if (points.Count < 3) throw new ArgumentException("A polygon needs three points.", nameof(points));
        double margin = style.Width + (style.Cloud > 0 ? CloudBorder.Bulge(style.Cloud) : 0);
        var d = NewAnnotation("Polygon", Inflate(BoundsOf(points), margin), info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        d["Vertices"] = Numbers(points.SelectMany(p => new[] { p.X, p.Y }));
        if (intent is not null) d["IT"] = new PdfName(intent);
        Decorate(d, style);
        return Place(page, d);
    }

    /// <summary>Freehand strokes, each a list of sampled points; they are drawn smoothed.</summary>
    public PdfAnnotation AddInk(PdfPage page, IReadOnlyList<IReadOnlyList<(double X, double Y)>> strokes, AnnotationStyle? style = null, AnnotationInfo? info = null)
    {
        var all = strokes.SelectMany(s => s).ToList();
        if (all.Count == 0) throw new ArgumentException("There are no points.", nameof(strokes));
        style ??= new AnnotationStyle();
        var d = NewAnnotation("Ink", Inflate(BoundsOf(all), style.Width / 2 + 1), info, style.Color ?? AppearanceBuilder.Red, style.Opacity);
        d["InkList"] = new PdfArray([.. strokes.Where(s => s.Count > 0).Select(s => (PdfObject)Numbers(s.SelectMany(p => new[] { p.X, p.Y })))]);
        SetBorder(d, style);
        return Place(page, d);
    }

    /// <summary>The /Rect of a line from (x1, y1) to (x2, y2): its end points with the room for the border and, with a head, for the head.</summary>
    internal static PdfRect LineBox(double x1, double y1, double x2, double y2, double width, bool head) =>
        Inflate(BoundsOf([(x1, y1), (x2, y2)]), Margin(new AnnotationStyle(Width: width), head));

    private static double Margin(AnnotationStyle style, bool endings) =>
        endings ? AppearanceBuilder.EndingSize(style.Width) + style.Width : style.Width / 2 + 1;

    private static PdfArray Endings(LineEnding start, LineEnding end) => new([new PdfName(start.ToString()), new PdfName(end.ToString())]);
}
