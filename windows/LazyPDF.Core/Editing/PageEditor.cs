namespace LazyPDF.Core;

/// <summary>The outcome of a change to text.</summary>
/// <param name="Done">The change was made and committed.</param>
/// <param name="Substitutions">Fonts that stood in for the one in the file.</param>
/// <param name="Grew">A paragraph took more lines than it had; the blocks below it stayed where they were.</param>
/// <param name="Overlaps">New text runs into text that follows it on the line, or off the page.</param>
/// <param name="Problem">Why nothing was done, when <paramref name="Done"/> is false.</param>
public sealed record TextEditResult(bool Done, IReadOnlyList<FontSubstitution> Substitutions, bool Grew, bool Overlaps, string? Problem)
{
    internal static TextEditResult Failed(string problem) => new(false, [], false, false, problem);
}

/// <summary>The outcome of a change to objects: how many were changed and which were left alone.</summary>
public sealed record ObjectEditResult(int Changed, IReadOnlyList<SkippedObject> Skipped)
{
    public bool Done => Changed > 0;
}

/// <summary>An object that could not be changed, and why.</summary>
public sealed record SkippedObject(int Id, string Reason);

/// <summary>
/// Changes what is already on one page: its text, images and paths. Each public change is one
/// <see cref="PdfEditSession.Commit"/>, so one undo step. The editor reads the page when asked and
/// again after each change; objects and ranges handed out earlier are stale after a change.
/// Everything is in user space.
/// </summary>
public sealed partial class PageEditor
{
    private readonly PdfEditSession _session;
    private readonly IFontSource? _fonts;
    private readonly IImageCodec? _codec;
    private PageModel? _model;
    private PdfDocument? _modelDocument;

    public PageEditor(PdfEditSession session, int pageIndex, IFontSource? fonts = null, IImageCodec? images = null)
    {
        if (pageIndex < 0 || pageIndex >= session.Document.Pages.Count) throw new ArgumentOutOfRangeException(nameof(pageIndex));
        _session = session;
        PageIndex = pageIndex;
        _fonts = fonts;
        _codec = images;
    }

    public int PageIndex { get; }

    /// <summary>The text, images and paths of the page in the order they are painted.</summary>
    public IReadOnlyList<PageObject> Objects => Model.Objects;

    /// <summary>The page's text as laid out, whose <see cref="TextRange"/>s the text changes take.</summary>
    public TextPage Text => Model.Text;

    /// <summary>Forgets what was read; the next member reads the page again.</summary>
    public void Refresh() => _model = null;

    internal PageModel Model
    {
        get
        {
            // A commit, undo or redo anywhere gives the session a new document.
            if (_model is null || !ReferenceEquals(_modelDocument, _session.Document))
            {
                _modelDocument = _session.Document;
                _model = PageModel.Load(_modelDocument, PageIndex);
            }
            return _model;
        }
    }

    /// <summary>The topmost object under the point, <paramref name="tolerance"/> user space units wide.</summary>
    public PageObject? HitTest(double x, double y, double tolerance = 1)
    {
        var objects = Model.Objects;
        for (int i = objects.Count - 1; i >= 0; i--)
        {
            if (Hits(objects[i], x, y, tolerance)) return objects[i];
        }
        return null;
    }

    /// <summary>The objects whose bounds touch the rectangle, or lie wholly inside it.</summary>
    public IReadOnlyList<PageObject> Select(PdfRect rect, bool contained = false) =>
    [
        .. Model.Objects.Where(o => contained
            ? o.Bounds.Left >= rect.Left && o.Bounds.Right <= rect.Right && o.Bounds.Bottom >= rect.Bottom && o.Bounds.Top <= rect.Top
            : o.Bounds.Left <= rect.Right && o.Bounds.Right >= rect.Left && o.Bounds.Bottom <= rect.Top && o.Bounds.Top >= rect.Bottom),
    ];

    private bool Hits(PageObject o, double x, double y, double tolerance)
    {
        var b = o.Bounds;
        if (x < b.Left - tolerance || x > b.Right + tolerance || y < b.Bottom - tolerance || y > b.Top + tolerance) return false;
        switch (o)
        {
            case TextObject text:
                return text.Glyphs.Any(g => g.Quad.DistanceTo(x, y) <= tolerance);
            case ImageObject image:
                if (image.Placement.Invert() is not { } inverse) return true;
                var (u, v) = inverse.Transform(x, y);
                double slack = tolerance / Math.Max(image.Placement.ScaleFactor, 1e-9);
                return u >= -slack && u <= 1 + slack && v >= -slack && v <= 1 + slack;
            case PathObject path:
                return PathHit.Contains(path, x, y, tolerance);
            default:
                return true;
        }
    }

    // Applies the batch, commits it as one step and forgets the model; a change that cannot be made is reported, not thrown.
    private TextEditResult Finish(string label, EditBatch batch, TextBuilder builder, TextEditor? editor = null)
    {
        try
        {
            batch.Apply();
            builder.WriteAdditions();
        }
        catch (EditConflictException e)
        {
            batch.Discard();
            return TextEditResult.Failed(e.Message);
        }
        bool done = _session.Commit(label);
        _model = null;
        return new TextEditResult(done, builder.Substitutions, editor?.Grew ?? false, editor?.Overlaps ?? false, done ? null : EditingText.NothingChanged);
    }

    private TextEditResult EditText(string label, Action<TextEditor> change)
    {
        var model = Model;
        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        var builder = new TextBuilder(model.Document, batch, _fonts);
        var editor = new TextEditor(model, batch, builder, _fonts);
        try
        {
            change(editor);
        }
        catch (EditConflictException e)
        {
            batch.Discard();
            return TextEditResult.Failed(e.Message);
        }
        return Finish(label, batch, builder, editor);
    }
}

/// <summary>Whether a point is on a path: inside its fill, or within reach of its stroke.</summary>
internal static class PathHit
{
    public static bool Contains(PathObject path, double x, double y, double tolerance)
    {
        var edges = new List<(double X1, double Y1, double X2, double Y2)>();
        double cx = 0, cy = 0, sx = 0, sy = 0;
        foreach (var s in path.Segments)
        {
            switch (s.Kind)
            {
                case PathSegmentKind.Move:
                    if (cx != sx || cy != sy) edges.Add((cx, cy, sx, sy));
                    (cx, cy, sx, sy) = (s.X1, s.Y1, s.X1, s.Y1);
                    break;
                case PathSegmentKind.Line:
                    edges.Add((cx, cy, s.X1, s.Y1));
                    (cx, cy) = (s.X1, s.Y1);
                    break;
                case PathSegmentKind.Curve:
                    double px = cx, py = cy;
                    for (int i = 1; i <= 8; i++)
                    {
                        double t = i / 8.0, u = 1 - t;
                        double qx = u * u * u * cx + 3 * u * u * t * s.X1 + 3 * u * t * t * s.X2 + t * t * t * s.X3;
                        double qy = u * u * u * cy + 3 * u * u * t * s.Y1 + 3 * u * t * t * s.Y2 + t * t * t * s.Y3;
                        edges.Add((px, py, qx, qy));
                        (px, py) = (qx, qy);
                    }
                    (cx, cy) = (s.X3, s.Y3);
                    break;
                case PathSegmentKind.Close:
                    edges.Add((cx, cy, sx, sy));
                    (cx, cy) = (sx, sy);
                    break;
            }
        }
        if (cx != sx || cy != sy) edges.Add((cx, cy, sx, sy));
        double reach = tolerance + (path.Stroke ? path.LineWidth / 2 : 0);
        if (path.Stroke || !path.Fill)
        {
            foreach (var e in edges)
            {
                if (Distance(e, x, y) <= reach) return true;
            }
        }
        if (!path.Fill) return false;
        int winding = 0, crossings = 0;
        foreach (var (x1, y1, x2, y2) in edges)
        {
            if ((y1 <= y) == (y2 <= y)) continue;
            double at = x1 + (y - y1) / (y2 - y1) * (x2 - x1);
            if (at > x) continue;
            crossings++;
            winding += y2 > y1 ? 1 : -1;
        }
        return path.EvenOdd ? crossings % 2 == 1 : winding != 0;
    }

    private static double Distance((double X1, double Y1, double X2, double Y2) e, double x, double y)
    {
        double dx = e.X2 - e.X1, dy = e.Y2 - e.Y1;
        double length2 = dx * dx + dy * dy;
        double t = length2 < 1e-12 ? 0 : Math.Clamp(((x - e.X1) * dx + (y - e.Y1) * dy) / length2, 0, 1);
        return Math.Sqrt(Math.Pow(x - (e.X1 + t * dx), 2) + Math.Pow(y - (e.Y1 + t * dy), 2));
    }
}
