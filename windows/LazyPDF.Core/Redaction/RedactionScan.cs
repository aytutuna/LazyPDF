using System.Text;

namespace LazyPDF.Core;

internal abstract record ContentEdit;

internal sealed record DeleteEdit : ContentEdit
{
    public static readonly DeleteEdit Instance = new();
}

/// <summary>Text around the operation, which stays in place: a clip with a hole in it for a shading.</summary>
internal sealed record SurroundEdit(string Before, string After) : ContentEdit;

/// <summary>Glyphs to cut out of the strings of one show operator, with the kerning that stands in for each.</summary>
internal sealed record TextEdit(Dictionary<(int Element, int Offset), (int Length, double Adjust)> Removed) : ContentEdit;

internal sealed record ImageEdit(PdfStream Image, List<MarkArea> Areas, PdfMatrix Matrix) : ContentEdit;

/// <summary>A painted path to remove, or for a rectangle fill the pieces left of it (in page space).</summary>
internal sealed record PathEdit(bool Clips, PdfMatrix Ctm, List<PdfRect>? Pieces) : ContentEdit;

/// <summary>One content stream in use: the page, or a form as it is painted at one place.</summary>
internal sealed class ScanNode(PdfStream? form)
{
    public PdfStream? Form { get; } = form;
    public Dictionary<int, ContentEdit> Edits { get; } = [];
    public Dictionary<int, ScanNode> Children { get; } = [];
    public HashSet<int> DirtyMarked { get; } = [];

    public bool HasEdits => Edits.Count > 0 || DirtyMarked.Count > 0 || Children.Values.Any(c => c.HasEdits);
}

/// <summary>
/// Walks a page and records what meets the marks, per content stream and operator index: glyphs,
/// paths, images, shadings and the marked content that held them.
/// </summary>
internal sealed class RedactionScan(IReadOnlyList<MarkArea> areas) : ContentVisitor
{
    private static readonly string[] AltKeys = ["ActualText", "Alt", "E"];
    private const int CurveSteps = 8;

    private readonly Stack<ScanNode> _nodes = new([new ScanNode(null)]);
    private readonly List<(ScanNode Node, int Op, MarkedContent Marked)> _open = [];
    private int _pattern;

    public ScanNode Root => _nodes.Last();
    public int Glyphs { get; private set; }
    public int Images { get; private set; }
    public int Paths { get; private set; }

    /// <summary>Painted items per page-level MCID, and how many of them were removed.</summary>
    public Dictionary<int, (int Total, int Removed)> Marked { get; } = [];

    private ScanNode Current => _nodes.Peek();

    public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
    {
        if (_pattern > 0) return;
        double width = glyph.Character.Width / 1000;
        var box = Geometry.Corners(glyph.Matrix, 0, glyph.Font.Descent / 1000, width, glyph.Font.Ascent / 1000);
        if (!areas.Any(a => Geometry.GlyphMeets(box, a)))
        {
            Count(context, false);
            return;
        }
        Count(context, true);
        Glyphs++;
        var state = context.State;
        double scale = glyph.Font.IsVertical ? state.FontSize : state.FontSize * state.HorizontalScale;
        double adjust = scale == 0 ? 0 : -glyph.Advance * 1000 / scale;
        if (!Current.Edits.TryGetValue(context.OperatorIndex, out var edit)) Current.Edits[context.OperatorIndex] = edit = new TextEdit([]);
        ((TextEdit)edit).Removed[(glyph.Element, glyph.Offset)] = (glyph.Character.Length, adjust);
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        if (_pattern > 0 || !(path.Fill || path.Stroke)) return;
        var hit = areas.Where(a => PathMeets(path, a)).ToList();
        if (hit.Count == 0)
        {
            Count(context, false);
            return;
        }
        Count(context, true);
        Paths++;
        var state = context.State;
        List<PdfRect>? pieces = null;
        if (path.Fill && !path.Stroke && !path.Clips && state.FillColor.Pattern is null && state.FillColor.PatternName is null
            && state.Ctm.Invert() is not null && AxisRectangle(path) is { } rect)
        {
            pieces = [rect];
            foreach (var area in hit) pieces = [.. pieces.SelectMany(p => Subtract(p, area.Bounds))];
        }
        Current.Edits[context.OperatorIndex] = new PathEdit(path.Clips, state.Ctm, pieces);
    }

    public override void PaintImage(ContentContext context, ImageInfo image)
    {
        if (_pattern > 0) return;
        var square = Geometry.Corners(image.Matrix, 0, 0, 1, 1);
        var hit = areas.Where(a => Geometry.Overlaps(square, a)).ToList();
        if (hit.Count == 0)
        {
            Count(context, false);
            return;
        }
        Count(context, true);
        Images++;
        Current.Edits[context.OperatorIndex] = image.Stream is { } stream ? new ImageEdit(stream, hit, image.Matrix) : DeleteEdit.Instance;
    }

    public override void PaintShading(ContentContext context, ShadingInfo shading)
    {
        if (_pattern > 0 || !areas.Any(a => Geometry.Meets(shading.Bounds, a))) return;
        var inverse = context.State.Ctm.Invert();
        if (inverse is not { } back) return;
        var everything = Geometry.Corners(back, -1e6, -1e6, 1e6, 1e6);
        var holes = areas.Select(a => a.Points.Select(p => back.Transform(p.X, p.Y)).ToList());
        var path = new StringBuilder("q\n");
        foreach (var polygon in holes.Prepend(everything)) Polygon(path, polygon);
        Current.Edits[context.OperatorIndex] = new SurroundEdit(path.Append("W* n\n").ToString(), "\nQ");
    }

    public override void BeginMarked(ContentContext context, MarkedContent marked) =>
        _open.Add((Current, context.OperatorIndex, marked));

    public override void EndMarked(ContentContext context, MarkedContent marked)
    {
        if (_open.Count > 0) _open.RemoveAt(_open.Count - 1);
    }

    public override void BeginForm(ContentContext context, FormInfo form)
    {
        if (form.IsPattern)
        {
            _pattern++;
            return;
        }
        var child = new ScanNode(form.Stream);
        Current.Children[context.OperatorIndex] = child;
        _nodes.Push(child);
    }

    public override void EndForm(ContentContext context, FormInfo form)
    {
        if (form.IsPattern) _pattern--;
        else _nodes.Pop();
    }

    private void Count(ContentContext context, bool removed)
    {
        if (removed)
        {
            // A description of the text in a sequence that lost some of it would give it away.
            foreach (var (node, op, marked) in _open)
            {
                if (marked.Properties is { } p && AltKeys.Any(p.ContainsKey)) node.DirtyMarked.Add(op);
            }
        }
        if (context.Forms.Count > 0 || context.Mcid is not { } mcid) return;
        var (total, gone) = Marked.GetValueOrDefault(mcid);
        Marked[mcid] = (total + 1, gone + (removed ? 1 : 0));
    }

    private static void Polygon(StringBuilder path, IReadOnlyList<(double X, double Y)> points)
    {
        for (int i = 0; i < points.Count; i++) path.Append(new PdfNumber(points[i].X).Text).Append(' ').Append(new PdfNumber(points[i].Y).Text).Append(i == 0 ? " m\n" : " l\n");
        path.Append("h\n");
    }

    public static string Polygons(IEnumerable<IReadOnlyList<(double X, double Y)>> polygons)
    {
        var path = new StringBuilder();
        foreach (var polygon in polygons) Polygon(path, polygon);
        return path.ToString();
    }

    private static List<List<(double X, double Y)>> Flatten(PathInfo path, out List<bool> closed)
    {
        var result = new List<List<(double X, double Y)>>();
        closed = [];
        List<(double X, double Y)>? current = null;
        (double X, double Y) last = default;
        foreach (var s in path.Segments)
        {
            switch (s.Kind)
            {
                case PathSegmentKind.Move:
                    current = [(s.X1, s.Y1)];
                    result.Add(current);
                    closed.Add(false);
                    last = (s.X1, s.Y1);
                    break;
                case PathSegmentKind.Line when current is not null:
                    current.Add(last = (s.X1, s.Y1));
                    break;
                case PathSegmentKind.Curve when current is not null:
                    var start = last;
                    for (int i = 1; i <= CurveSteps; i++)
                    {
                        double t = (double)i / CurveSteps, u = 1 - t;
                        current.Add((u * u * u * start.X + 3 * u * u * t * s.X1 + 3 * u * t * t * s.X2 + t * t * t * s.X3,
                                     u * u * u * start.Y + 3 * u * u * t * s.Y1 + 3 * u * t * t * s.Y2 + t * t * t * s.Y3));
                    }
                    last = (s.X3, s.Y3);
                    break;
                case PathSegmentKind.Close when current is not null:
                    closed[^1] = true;
                    last = current[0];
                    break;
            }
        }
        return result;
    }

    private static bool PathMeets(PathInfo path, MarkArea area)
    {
        var ink = path.InkBounds;
        if (ink.Right < area.Bounds.Left || ink.Left > area.Bounds.Right || ink.Top < area.Bounds.Bottom || ink.Bottom > area.Bounds.Top) return false;
        var subpaths = Flatten(path, out var closed);
        double half = Math.Max(0, (path.InkBounds.Width - path.Bounds.Width) / 2);
        for (int s = 0; s < subpaths.Count; s++)
        {
            var points = subpaths[s];
            bool wrap = path.Fill || closed[s];
            for (int i = 0; i < points.Count; i++)
            {
                if (i + 1 == points.Count && !wrap) break;
                double reach = Geometry.Distance(points[i], points[(i + 1) % points.Count], area);
                if (path.Fill && reach == 0) return true;
                if (path.Stroke && reach <= half) return true;
            }
        }
        if (!path.Fill) return false;
        var inside = area.Points.Append((X: area.Points.Average(p => p.X), Y: area.Points.Average(p => p.Y)));
        return inside.Any(p => Geometry.Inside(subpaths, path.EvenOdd, p.X, p.Y));
    }

    private static PdfRect? AxisRectangle(PathInfo path)
    {
        var points = new List<(double X, double Y)>();
        foreach (var s in path.Segments)
        {
            if (s.Kind == PathSegmentKind.Move && points.Count == 0) points.Add((s.X1, s.Y1));
            else if (s.Kind == PathSegmentKind.Line) points.Add((s.X1, s.Y1));
            else if (s.Kind != PathSegmentKind.Close) return null;
        }
        if (points.Count == 5 && Near(points[0], points[4])) points.RemoveAt(4);
        if (points.Count != 4) return null;
        bool horizontalFirst = Same(points[0].Y, points[1].Y) && Same(points[1].X, points[2].X) && Same(points[2].Y, points[3].Y) && Same(points[3].X, points[0].X);
        bool verticalFirst = Same(points[0].X, points[1].X) && Same(points[1].Y, points[2].Y) && Same(points[2].X, points[3].X) && Same(points[3].Y, points[0].Y);
        if (!horizontalFirst && !verticalFirst) return null;
        return new PdfRect(points.Min(p => p.X), points.Min(p => p.Y), points.Max(p => p.X), points.Max(p => p.Y));
    }

    private static bool Same(double a, double b) => Math.Abs(a - b) < 1e-6;

    private static bool Near((double X, double Y) a, (double X, double Y) b) => Same(a.X, b.X) && Same(a.Y, b.Y);

    // The rectangle with the mark's box taken out: a band to the left and right over the full height
    // and the strips above and below between them.
    private static IEnumerable<PdfRect> Subtract(PdfRect r, PdfRect cut)
    {
        if (cut.Right <= r.Left || cut.Left >= r.Right || cut.Top <= r.Bottom || cut.Bottom >= r.Top)
        {
            yield return r;
            yield break;
        }
        double left = Math.Max(cut.Left, r.Left), right = Math.Min(cut.Right, r.Right);
        if (cut.Left > r.Left) yield return new PdfRect(r.Left, r.Bottom, cut.Left, r.Top);
        if (cut.Right < r.Right) yield return new PdfRect(cut.Right, r.Bottom, r.Right, r.Top);
        if (cut.Top < r.Top) yield return new PdfRect(left, cut.Top, right, r.Top);
        if (cut.Bottom > r.Bottom) yield return new PdfRect(left, r.Bottom, right, cut.Bottom);
    }
}
