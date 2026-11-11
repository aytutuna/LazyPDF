using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tools.Comment;

public enum MarkTool
{
    SelectText,
    Edit,
    Note,
    TextBox,
    Callout,
    Line,
    Arrow,
    Rectangle,
    Oval,
    Polygon,
    Cloud,
    Pencil,
    Eraser,
    Stamp,
    Attach,
}

public enum LineStyle
{
    Solid,
    Dashed,
    Dotted,
}

/// <summary>How a new mark looks. A null colour takes the default of its kind.</summary>
public sealed record MarkStyle(double[]? Color, double Width, double Opacity, string Family, double Size, FontStyles Font, double[]? Fill = null, LineStyle Dash = LineStyle.Solid, LineEnding Head = LineEnding.OpenArrow, string Icon = "Note")
{
    public static MarkStyle Default { get; } = new(null, 2, 1, "Helvetica", 12, FontStyles.Regular);

    public AnnotationStyle ToAnnotation() => new(Color, Width, DashesOf(Dash, Width), Fill, Opacity);

    public static double[]? DashesOf(LineStyle style, double width)
    {
        double w = Math.Max(width, 1);
        return style switch
        {
            LineStyle.Dashed => [3 * w, 2 * w],
            LineStyle.Dotted => [w, w + 1],
            _ => null,
        };
    }

    public FreeTextStyle ToText() => new(Family, Size, Font, Color ?? [0, 0, 0]);
}

/// <summary>Adds, changes and finds marks on the open document. Page points are in the display space the viewer uses.</summary>
public sealed partial class Marker(PdfDocument document, IFontSource fonts, string author, DateTimeOffset date)
{
    public const double NoteSize = 20;
    public const double CalloutWidth = 150;
    public const double CalloutHeight = 50;
    public const double StampWidth = 130;
    public const double DatedStampWidth = 220;
    public const double StampHeight = 44;

    private readonly PdfAnnotationWriter _writer = new(document, fonts);

    private AnnotationInfo Info(string text = "") => new(author, text, null, date);

    // On a turned page text and stamps are told to stay upright (NoRotate), their natural size hung from the corner shown top left.
    private AnnotationInfo Upright(PageGeometry geometry, string text = "") =>
        geometry.Rotation == 0 ? Info(text) : Info(text) with { Flags = AnnotationFlags.Print | AnnotationFlags.NoRotate };

    private static PdfRect Standing(PageGeometry geometry, Rect box) => geometry.Rotation is 90 or 270
        ? geometry.ToUser(new DisplayRect(box.X, box.Y, box.Height, box.Width))
        : geometry.ToUser(new DisplayRect(box.X, box.Y, box.Width, box.Height));

    private static bool Stands(PdfAnnotation a, PageGeometry geometry) => a.Flags.HasFlag(AnnotationFlags.NoRotate) && geometry.Rotation != 0;

    private PdfAnnotation Faded(PdfAnnotation made, MarkStyle style) => style.Opacity < 1 ? _writer.SetOpacity(made, style.Opacity) : made;

    public static MarkupQuad Quad(TextQuad q) => new(q.X3, q.Y3, q.X2, q.Y2, q.X0, q.Y0, q.X1, q.Y1);

    public int Markup(AnnotationType kind, IEnumerable<SelectedRun> runs, MarkStyle style)
    {
        int count = 0;
        foreach (var run in runs)
        {
            if (run.Quads.Count == 0 || run.Page >= document.Pages.Count) continue;
            _writer.AddTextMarkup(document.Pages[run.Page], kind, [.. run.Quads.Select(Quad)], Info(), style.ToAnnotation());
            count++;
        }
        return count;
    }

    /// <summary>The box a text box or callout takes from the points the user gave, in display space.</summary>
    public static Rect BoxOf(MarkTool tool, IReadOnlyList<Point> points)
    {
        if (tool == MarkTool.Callout) return new Rect(points[^1].X - CalloutWidth / 2, points[^1].Y - CalloutHeight / 2, CalloutWidth, CalloutHeight);
        return new Rect(points[0], points[^1]);
    }

    public PdfAnnotation Add(MarkTool tool, int page, IReadOnlyList<Point> points, MarkStyle style, string text = "")
    {
        var target = document.Pages[page];
        var geometry = new PageGeometry(target);
        (double X, double Y) User(Point p) => geometry.ToUser(p.X, p.Y);
        PdfRect UserRect(Rect r) => geometry.ToUser(new DisplayRect(r.X, r.Y, r.Width, r.Height));
        var shape = style.ToAnnotation();
        var upright = Upright(geometry, text);
        switch (tool)
        {
            case MarkTool.Note:
                return Faded(_writer.AddNote(target, UserRect(new Rect(points[0], new Size(NoteSize, NoteSize))), Info(text), style.Icon, style.Color), style);
            case MarkTool.TextBox:
                return _writer.AddFreeText(target, Standing(geometry, BoxOf(tool, points)), text, style.ToText(), shape with { Width = 0, Dash = null, Fill = null }, upright);
            case MarkTool.Callout:
            {
                var box = BoxOf(tool, points);
                var anchor = points[0];
                var edge = new[]
                {
                    new Point(box.Left, box.Top + box.Height / 2), new Point(box.Right, box.Top + box.Height / 2),
                    new Point(box.Left + box.Width / 2, box.Top), new Point(box.Left + box.Width / 2, box.Bottom),
                }.MinBy(p => (p - anchor).LengthSquared);
                var framed = shape with { Width = Math.Max(1, style.Width) };
                if (geometry.Rotation == 0) return _writer.AddFreeText(target, UserRect(box), text, style.ToText(), framed, upright, [User(anchor), User(edge)]);
                // A callout line is drawn in user space and would turn the text with the page, so a turned page gets a box and an arrow.
                var boxed = _writer.AddFreeText(target, Standing(geometry, box), text, style.ToText(), framed, upright);
                _writer.AddArrow(target, User(edge), User(anchor), shape, Info());
                return boxed;
            }
            case MarkTool.Line:
                return _writer.AddLine(target, User(points[0]), User(points[^1]), shape, Info());
            case MarkTool.Arrow:
            {
                var arrow = _writer.AddLine(target, User(points[0]), User(points[^1]), shape, Info(), LineEnding.None, style.Head);
                arrow.Dictionary["IT"] = new PdfName("LineArrow");
                return arrow;
            }
            case MarkTool.Rectangle:
                return _writer.AddSquare(target, UserRect(new Rect(points[0], points[^1])), shape, Info());
            case MarkTool.Oval:
                return _writer.AddCircle(target, UserRect(new Rect(points[0], points[^1])), shape, Info());
            case MarkTool.Polygon:
                return _writer.AddPolygon(target, [.. points.Select(User)], shape, Info());
            case MarkTool.Cloud:
                return _writer.AddCloud(target, [.. points.Select(User)], shape with { Cloud = 2 }, Info());
            case MarkTool.Pencil:
                return _writer.AddInk(target, [[.. points.Select(User)]], shape with { Fill = null }, Info());
            default:
                throw new ArgumentException("This tool does not draw by itself.", nameof(tool));
        }
    }

    public PdfAnnotation AddStamp(int page, Point center, string name, MarkStyle style, bool dated = false)
    {
        var target = document.Pages[page];
        var geometry = new PageGeometry(target);
        double width = dated ? DatedStampWidth : StampWidth;
        var box = Standing(geometry, new Rect(center.X - width / 2, center.Y - StampHeight / 2, width, StampHeight));
        return Faded(_writer.AddStamp(target, box, name, Upright(geometry), style.Color), style);
    }

    public PdfAnnotation AddPictureStamp(int page, Point center, PdfRgbaImage image)
    {
        var geometry = new PageGeometry(document.Pages[page]);
        double aspect = image.Width / (double)image.Height;
        var box = FillSignPlacement.Around(center, Math.Min(StampWidth, StampWidth * aspect), aspect, new Size(geometry.Width, geometry.Height));
        return FillSignPlacement.AddImage(document, page, box, image, author, date);
    }

    // Core picks a stamp's colour by its exact name, which a dated name no longer is.
    public static double[] StampColor(string name) => name switch
    {
        "Approved" or "Final" or "ForPublicRelease" => [0, 0.5, 0.15],
        "AsIs" or "Experimental" or "Sold" or "Departmental" or "ForComment" => [0, 0.2, 0.7],
        _ => [0.75, 0, 0],
    };

    public PdfAnnotation AddAttachment(int page, Point at, string fileName, byte[] data)
    {
        var target = document.Pages[page];
        var box = new PageGeometry(target).ToUser(new DisplayRect(at.X, at.Y, NoteSize, NoteSize));
        return _writer.AddFileAttachment(target, box, fileName, data, Info(), "PushPin");
    }

    public PdfAnnotation? Find(int page, int number) =>
        page < 0 || page >= document.Pages.Count ? null : PdfAnnotations.Read(document, document.Pages[page]).FirstOrDefault(a => a.Reference?.Number == number);

    /// <summary>The topmost mark under a point of the page, if any.</summary>
    public PdfAnnotation? At(int page, Point point, double tolerance)
    {
        if (page < 0 || page >= document.Pages.Count) return null;
        var target = document.Pages[page];
        var (x, y) = new PageGeometry(target).ToUser(point.X, point.Y);
        var marks = PdfAnnotations.Read(document, target);
        for (int i = marks.Count - 1; i >= 0; i--)
        {
            if (Selectable(marks[i]) && Covers(marks[i], x, y, tolerance)) return marks[i];
        }
        return null;
    }

    /// <summary>The marks that a stroke of the pointer crosses, also between the points it was sampled at.</summary>
    public IReadOnlyList<PdfAnnotation> Along(int page, IReadOnlyList<Point> path, double tolerance)
    {
        if (page < 0 || page >= document.Pages.Count || path.Count == 0) return [];
        var target = document.Pages[page];
        var geometry = new PageGeometry(target);
        var marks = PdfAnnotations.Read(document, target).Where(Selectable).ToList();
        var hit = new Dictionary<int, PdfAnnotation>();
        foreach (var point in Densify(path, tolerance))
        {
            var (x, y) = geometry.ToUser(point.X, point.Y);
            foreach (var mark in marks)
            {
                if (!hit.ContainsKey(mark.Reference!.Number) && Covers(mark, x, y, tolerance)) hit[mark.Reference.Number] = mark;
            }
        }
        return [.. hit.Values];
    }

    private static IEnumerable<Point> Densify(IReadOnlyList<Point> path, double step)
    {
        yield return path[0];
        for (int i = 1; i < path.Count; i++)
        {
            var span = path[i] - path[i - 1];
            int parts = Math.Max(1, (int)Math.Ceiling(span.Length / step));
            for (int k = 1; k <= parts; k++) yield return path[i - 1] + span * k / parts;
        }
    }

    /// <summary>A mark the user may pick: not a reply or a hidden one, and not one the file locks.</summary>
    public static bool Selectable(PdfAnnotation a) =>
        a.IsMarkup && a.Reference is not null && a.InReplyTo is null && !a.Flags.HasFlag(AnnotationFlags.Hidden)
        && !a.Flags.HasFlag(AnnotationFlags.Locked) && !a.Flags.HasFlag(AnnotationFlags.ReadOnly);

    /// <summary>A mark the eraser takes: ink, lines and shapes, but not a measurement, which the Measure tool owns.</summary>
    public static bool Erasable(PdfAnnotation a) =>
        a.Type is AnnotationType.Ink or AnnotationType.Line or AnnotationType.PolyLine or AnnotationType.Polygon or AnnotationType.Square or AnnotationType.Circle
        && !a.Dictionary.ContainsKey("Measure");

    private static bool Covers(PdfAnnotation a, double x, double y, double tolerance)
    {
        double reach = tolerance + a.Border.Width / 2;
        switch (a.Type)
        {
            case AnnotationType.Line when a.Line.Count >= 4:
                return Near(a.Line, closed: false, x, y, reach);
            case AnnotationType.PolyLine when a.Vertices.Count >= 4:
                return Near(a.Vertices, closed: false, x, y, reach);
            case AnnotationType.Polygon when a.Vertices.Count >= 4:
                return Near(a.Vertices, closed: true, x, y, reach);
            case AnnotationType.Square when a.InteriorColor is not { Count: > 0 }:
                return Near([a.Rect.Left, a.Rect.Bottom, a.Rect.Right, a.Rect.Bottom, a.Rect.Right, a.Rect.Top, a.Rect.Left, a.Rect.Top], closed: true, x, y, reach);
            case AnnotationType.Circle when a.InteriorColor is not { Count: > 0 }:
                return OnEllipse(a.Rect, x, y, reach);
            case AnnotationType.Ink:
                return a.InkList.Any(stroke => Near(stroke, closed: false, x, y, reach));
            case AnnotationType.Highlight or AnnotationType.Underline or AnnotationType.StrikeOut or AnnotationType.Squiggly when a.Quads.Count > 0:
                return a.Quads.Any(q => Inside(q.Bounds, x, y, tolerance));
            default:
                return Inside(a.Rect, x, y, tolerance);
        }
    }

    private static bool Inside(PdfRect r, double x, double y, double by) =>
        x >= r.Left - by && x <= r.Right + by && y >= r.Bottom - by && y <= r.Top + by;

    private static bool OnEllipse(PdfRect r, double x, double y, double reach)
    {
        double rx = r.Width / 2, ry = r.Height / 2;
        if (rx <= 0 || ry <= 0) return Inside(r, x, y, reach);
        double d = Math.Sqrt(Math.Pow((x - r.Left - rx) / rx, 2) + Math.Pow((y - r.Bottom - ry) / ry, 2));
        return Math.Abs(d - 1) * Math.Min(rx, ry) <= reach;
    }

    private static bool Near(IReadOnlyList<double> xy, bool closed, double x, double y, double reach)
    {
        int n = xy.Count / 2;
        if (n == 1) return Distance(xy[0], xy[1], xy[0], xy[1], x, y) <= reach;
        for (int i = 0; i < (closed ? n : n - 1); i++)
        {
            int j = (i + 1) % n;
            if (Distance(xy[2 * i], xy[2 * i + 1], xy[2 * j], xy[2 * j + 1], x, y) <= reach) return true;
        }
        return false;
    }

    private static double Distance(double ax, double ay, double bx, double by, double x, double y)
    {
        double dx = bx - ax, dy = by - ay;
        double length = dx * dx + dy * dy;
        double t = length == 0 ? 0 : Math.Clamp(((x - ax) * dx + (y - ay) * dy) / length, 0, 1);
        return Math.Sqrt(Math.Pow(x - (ax + t * dx), 2) + Math.Pow(y - (ay + t * dy), 2));
    }

    /// <summary>False when the annotation's page is no longer in the file.</summary>
    public bool OnPage(PdfAnnotation a) => a.PageIndex >= 0 && a.PageIndex < document.Pages.Count;

    /// <summary>The annotation's box in display space.</summary>
    public Rect BoxOf(PdfAnnotation a)
    {
        var page = document.Pages[a.PageIndex];
        var geometry = new PageGeometry(page);
        var box = geometry.ToDisplay(a.Rect);
        if (Stands(a, geometry)) return new Rect(box.X, box.Y, a.Rect.Width * page.UserUnit, a.Rect.Height * page.UserUnit);
        return new Rect(box.X, box.Y, box.Width, box.Height);
    }

    public PdfAnnotation Move(PdfAnnotation a, Vector shift)
    {
        var geometry = new PageGeometry(document.Pages[a.PageIndex]);
        var (x0, y0) = geometry.ToUser(0, 0);
        var (x1, y1) = geometry.ToUser(shift.X, shift.Y);
        return _writer.Move(a, x1 - x0, y1 - y0);
    }

    private static string PointKey(PdfAnnotation a) => a.Type == AnnotationType.Line ? "L" : "Vertices";

    private static IReadOnlyList<double>? UserPoints(PdfAnnotation a) => a.Type switch
    {
        AnnotationType.Line when a.Line.Count >= 4 => a.Line,
        AnnotationType.PolyLine or AnnotationType.Polygon when a.Vertices.Count >= 4 => a.Vertices,
        _ => null,
    };

    /// <summary>The ends of a line or the corners of a polygon in display space; null for a mark that moves only by its box, and for a measurement.</summary>
    public Point[]? PointsOf(PdfAnnotation a)
    {
        if (UserPoints(a) is not { } xy || a.Dictionary.ContainsKey("Measure")) return null;
        var geometry = new PageGeometry(document.Pages[a.PageIndex]);
        int count = a.Type == AnnotationType.Line ? 2 : xy.Count / 2;
        return [.. Enumerable.Range(0, count).Select(i =>
        {
            var (x, y) = geometry.ToDisplay(xy[2 * i], xy[2 * i + 1]);
            return new Point(x, y);
        })];
    }

    /// <summary>Moves one end or corner and keeps the room the box had around the points for the border and the heads.</summary>
    public PdfAnnotation MovePoint(PdfAnnotation a, int index, Point to)
    {
        if (PointsOf(a) is null || UserPoints(a) is not { } old) throw new ArgumentException("This mark has no points to move.", nameof(a));
        var (x, y) = new PageGeometry(document.Pages[a.PageIndex]).ToUser(to.X, to.Y);
        double[] xy = [.. old];
        xy[2 * index] = x;
        xy[2 * index + 1] = y;
        double[] oldX = [.. old.Where((_, i) => i % 2 == 0)], oldY = [.. old.Where((_, i) => i % 2 == 1)];
        double[] newX = [.. xy.Where((_, i) => i % 2 == 0)], newY = [.. xy.Where((_, i) => i % 2 == 1)];
        a.Dictionary[PointKey(a)] = new PdfArray([.. xy.Select(v => (PdfObject)new PdfNumber(v))]);
        a.Dictionary["Rect"] = new PdfRect(
            newX.Min() - (oldX.Min() - a.Rect.Left), newY.Min() - (oldY.Min() - a.Rect.Bottom),
            newX.Max() + (a.Rect.Right - oldX.Max()), newY.Max() + (a.Rect.Top - oldY.Max())).ToArray();
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    public PdfAnnotation Resize(PdfAnnotation a, Rect box)
    {
        var geometry = new PageGeometry(document.Pages[a.PageIndex]);
        var rect = Stands(a, geometry) ? Standing(geometry, box) : geometry.ToUser(new DisplayRect(box.X, box.Y, box.Width, box.Height));
        var resized = _writer.Resize(a, rect);
        // The writer scales the rectangle and the callout line but not the insets that place the box in it.
        if (a.RectDifference.Count != 4 || a.Rect.Width <= 0 || a.Rect.Height <= 0) return resized;
        double sx = rect.Width / a.Rect.Width, sy = rect.Height / a.Rect.Height;
        double[] scale = [sx, sy, sx, sy];
        resized.Dictionary["RD"] = new PdfArray([.. a.RectDifference.Select((v, i) => (PdfObject)new PdfNumber(v * scale[i]))]);
        _writer.Regenerate(resized);
        return Find(a.PageIndex, a.Reference!.Number) ?? resized;
    }

    /// <summary>Paints the mark's outline, not its fill; a text box takes the colour for its frame and its text.</summary>
    public PdfAnnotation Recolor(PdfAnnotation a, double[] color)
    {
        var painted = _writer.SetColor(a, color);
        return a.Type != AnnotationType.FreeText ? painted : _writer.SetFreeTextStyle(painted, TextOf(painted) with { TextColor = color, RichText = null });
    }

    /// <summary>Fills the mark with the colour, or takes the fill away for null.</summary>
    public PdfAnnotation SetFill(PdfAnnotation a, double[]? rgb)
    {
        if (rgb is null) a.Dictionary.Remove("IC");
        else a.Dictionary["IC"] = new PdfArray([.. rgb.Select(v => (PdfObject)new PdfNumber(v))]);
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    public PdfAnnotation SetDash(PdfAnnotation a, LineStyle style)
    {
        var border = (document.Dict(a.Dictionary, "BS") ?? new PdfDictionary()).Copy();
        var dashes = MarkStyle.DashesOf(style, a.Border.Width);
        border["S"] = new PdfName(dashes is null ? "S" : "D");
        if (dashes is null) border.Remove("D");
        else border["D"] = new PdfArray([.. dashes.Select(v => (PdfObject)new PdfNumber(v))]);
        a.Dictionary["BS"] = border;
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    /// <summary>Gives a line the head at its end and room in its box to show it.</summary>
    public PdfAnnotation SetEnding(PdfAnnotation a, LineEnding head)
    {
        a.Dictionary["LE"] = new PdfArray([new PdfName(LineEnding.None.ToString()), new PdfName(head.ToString())]);
        double grow = 4 * a.Border.Width;
        a.Dictionary["Rect"] = new PdfRect(a.Rect.Left - grow, a.Rect.Bottom - grow, a.Rect.Right + grow, a.Rect.Top + grow).ToArray();
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    public PdfAnnotation SetIcon(PdfAnnotation a, string name)
    {
        a.Dictionary["Name"] = new PdfName(name);
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    /// <summary>How the mark's outline is drawn; a dash as long as three line widths is dashed, a shorter one dotted.</summary>
    public static LineStyle LineOf(PdfAnnotation a) =>
        a.Border.Style != BorderStyle.Dashed ? LineStyle.Solid
        : a.Border.Dash.Count > 0 && a.Border.Dash[0] >= 2 * Math.Max(a.Border.Width, 1) ? LineStyle.Dashed : LineStyle.Dotted;

    public static bool TakesLine(MarkTool tool) =>
        tool is MarkTool.Callout or MarkTool.Line or MarkTool.Arrow or MarkTool.Rectangle or MarkTool.Oval or MarkTool.Polygon or MarkTool.Cloud or MarkTool.Pencil;

    public static bool TakesFill(MarkTool tool) => tool != MarkTool.Pencil && TakesLine(tool);

    public static bool TakesLine(PdfAnnotation a) =>
        a.Type is AnnotationType.Line or AnnotationType.PolyLine or AnnotationType.Polygon or AnnotationType.Square or AnnotationType.Circle or AnnotationType.Ink
        || a is { Type: AnnotationType.FreeText, Callout.Count: >= 4 };

    public static bool TakesFill(PdfAnnotation a) => a.Type != AnnotationType.Ink && TakesLine(a);

    public PdfAnnotation SetOpacity(PdfAnnotation a, double opacity) => _writer.SetOpacity(a, opacity);

    public PdfAnnotation SetWidth(PdfAnnotation a, double width)
    {
        var border = (document.Dict(a.Dictionary, "BS") ?? new PdfDictionary()).Copy();
        var dashes = LineOf(a) == LineStyle.Solid ? null : MarkStyle.DashesOf(LineOf(a), width);
        border["W"] = new PdfNumber(width);
        if (dashes is not null) border["D"] = new PdfArray([.. dashes.Select(v => (PdfObject)new PdfNumber(v))]);
        a.Dictionary["BS"] = border;
        _writer.Regenerate(a);
        return Find(a.PageIndex, a.Reference!.Number) ?? a;
    }

    public PdfAnnotation SetText(PdfAnnotation a, string text) => _writer.SetContents(a, text, date);

    /// <summary>Gives a text box the font, size and style of <paramref name="style"/> and keeps its colour and alignment. Rich text goes, as it would hide the change.</summary>
    public PdfAnnotation Restyle(PdfAnnotation a, MarkStyle style) =>
        _writer.SetFreeTextStyle(a, TextOf(a) with { Family = style.Family, Size = style.Size, Font = style.Font, RichText = null });

    public bool Delete(PdfAnnotation a) => _writer.Delete(a);

    [GeneratedRegex(@"/(\w+)\s+([\d.]+)\s+Tf")]
    private static partial Regex FaceOperator();

    [GeneratedRegex(@"font-family:\s*([^;]+)")]
    private static partial Regex StyleFamily();

    [GeneratedRegex(@"((?:-?[\d.]+\s+){1,4})(?:g|rg|k)\b")]
    private static partial Regex FillOperator();

    /// <summary>What a text box is set in, read from its /DA.</summary>
    public static FreeTextStyle TextOf(PdfAnnotation a)
    {
        string da = a.DefaultAppearance ?? "";
        string family = "Helvetica";
        double size = 12;
        var font = FontStyles.Regular;
        if (FaceOperator().Match(da) is { Success: true } face)
        {
            string name = face.Groups[1].Value;
            family = name.StartsWith("Ti", StringComparison.Ordinal) ? "Times New Roman" : name.StartsWith("Co", StringComparison.Ordinal) ? "Courier New" : "Helvetica";
            if (name.EndsWith("Bo") || name.EndsWith("BI") || name.EndsWith("BO")) font |= FontStyles.Bold;
            if (name.EndsWith("It") || name.EndsWith("Ob") || name.EndsWith("BI") || name.EndsWith("BO")) font |= FontStyles.Italic;
            if (double.TryParse(face.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed)) size = parsed;
        }
        // Writing /DA keeps only the three standard families, but /DS still names the one another app used.
        if (family == "Helvetica" && StyleFamily().Match(a.DefaultStyle ?? "") is { Success: true } named) family = FirstFamily(named.Groups[1].Value);
        double[]? color = null;
        if (FillOperator().Matches(da).LastOrDefault() is { } fill)
        {
            var values = fill.Groups[1].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select(v => double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out double n) ? n : double.NaN).ToArray();
            if (values.All(double.IsFinite)) color = values;
        }
        return new FreeTextStyle(family, size, font, color, a.Alignment, a.RichText);
    }

    private static string FirstFamily(string list)
    {
        string first = list.Split(',')[0].Trim().Trim('"', '\'').Trim();
        return first.ToLowerInvariant() switch
        {
            "serif" or "times" or "times new roman" => "Times New Roman",
            "monospace" or "courier" or "courier new" => "Courier New",
            "sans-serif" or "cursive" or "fantasy" or "helvetica" => "Helvetica",
            _ => first,
        };
    }

    /// <summary>A colour of gray, RGB or CMYK as RGB; null for anything else, and for none.</summary>
    public static double[]? RgbOf(IReadOnlyList<double>? color) => color switch
    {
        [var g] => [g, g, g],
        [var r, var g, var b] => [r, g, b],
        [var c, var m, var y, var k] => [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)],
        _ => null,
    };
}
