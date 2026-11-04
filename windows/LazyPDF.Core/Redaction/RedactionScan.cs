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

/// <summary>A painted or clipping path to remove, and the polygons left of it outside the marks (in page space; none for a path that goes whole).</summary>
internal sealed record PathEdit(bool Clips, PdfMatrix Ctm, List<List<(double X, double Y)>> Remains) : ContentEdit;

/// <summary>One content stream in use: the page, or a form as it is painted at one place.</summary>
internal sealed class ScanNode(PdfStream? form)
{
    public PdfStream? Form { get; } = form;
    public Dictionary<int, ContentEdit> Edits { get; } = [];
    public Dictionary<int, ScanNode> Children { get; } = [];
    public Dictionary<int, PdfDictionary> DirtyMarked { get; } = [];

    public bool HasEdits => Edits.Count > 0 || DirtyMarked.Count > 0 || Children.Values.Any(c => c.HasEdits);
}

/// <summary>
/// Walks a page and records what meets the marks, per content stream and operator index: glyphs,
/// paths, images, shadings and the marked content that held them. What it meets under a soft mask,
/// with a pattern, or in optional content it does not take out: <see cref="Unhandled"/> says so, and the page is
/// not redacted in place.
/// </summary>
internal sealed class RedactionScan(IReadOnlyList<MarkArea> areas) : ContentVisitor
{
    private readonly Stack<ScanNode> _nodes = new([new ScanNode(null)]);
    private readonly List<(ScanNode Node, int Op, MarkedContent Marked)> _open = [];
    private readonly Dictionary<(PdfDictionary Font, int Code), PdfRect?> _inks = new();
    private LayerVisibility? _layers;
    private HashSet<PdfDictionary>? _declared;

    public ScanNode Root => _nodes.Last();
    public int Glyphs { get; private set; }
    public int Images { get; private set; }
    public int Paths { get; private set; }

    /// <summary>Something under a mark is painted through a soft mask, a pattern or optional content.</summary>
    public bool Unhandled { get; private set; }

    /// <summary>How many times each form or picture has something cut out of it; every other use of it still names the original.</summary>
    public Dictionary<PdfStream, int> Edited { get; } = new(ReferenceEqualityComparer.Instance);

    /// <summary>Painted items per page-level MCID, and how many of them were removed.</summary>
    public Dictionary<int, (int Total, int Removed)> Marked { get; } = [];

    private ScanNode Current => _nodes.Peek();

    public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
    {
        var font = glyph.Font;
        // The same limits TextCollector puts on a descriptor, so that the box is where the text is read from.
        double ascent = font.IsType3 ? (font.Ascent > 0 ? font.Ascent / 1000 : 0.8) : Math.Max(font.Ascent > 0 ? Math.Min(font.Ascent / 1000, 1.1) : 0.8, 0.5);
        double descent = font.Descent < 0 ? (font.IsType3 ? font.Descent / 1000 : Math.Max(font.Descent / 1000, -0.4)) : -0.2;
        var box = Geometry.Corners(glyph.Matrix, 0, descent, glyph.Character.Width / 1000, ascent);
        if (!areas.Any(a => Geometry.GlyphMeets(box, a)) && !(glyph.Font.IsType3 && InkMeets(context.Document, glyph)))
        {
            Count(context, false);
            return;
        }
        Count(context, true);
        Glyphs++;
        // The procedure of a glyph that goes stays in the font, and a bitmap glyph is a picture that stays with it.
        if (glyph.Font.IsType3) Unhandled = true;
        var state = context.State;
        Guard(context, state.RenderMode is 0 or 2 or 4 or 6, state.RenderMode is 1 or 2 or 5 or 6, null);
        double scale = glyph.Font.IsVertical ? state.FontSize : state.FontSize * state.HorizontalScale;
        double adjust = scale == 0 ? 0 : -glyph.Advance * 1000 / scale;
        if (!Current.Edits.TryGetValue(context.OperatorIndex, out var edit)) Current.Edits[context.OperatorIndex] = edit = new TextEdit([]);
        ((TextEdit)edit).Removed[(glyph.Element, glyph.Offset)] = (glyph.Character.Length, adjust);
    }

    // A procedure paints where it pleases (9.6.5), so a Type 3 glyph goes when what it paints meets a mark, whatever its box.
    private bool InkMeets(PdfDocument document, in GlyphInfo glyph)
    {
        var key = (glyph.Font.Dictionary, glyph.Code);
        if (!_inks.TryGetValue(key, out var ink))
        {
            _inks[key] = ink = RedactionGlyphs.Procedure(document, glyph.Font, glyph.Code) is { } procedure ? RedactionGlyphs.Ink(document, glyph.Font, procedure) : null;
        }
        if (ink is not { IsEmpty: false } box) return false;
        var drawn = Geometry.Corners(glyph.Matrix, box.Left, box.Bottom, box.Right, box.Top);
        return areas.Any(a => Geometry.Overlaps(drawn, a));
    }

    // A soft mask (11.6.5.2) or a pattern with anything but shapes in it (8.7) paints through a shape the scan does not enter,
    // and optional content (8.11) can hide what is under a mark from the viewer while it stays in the file. Taking the shape
    // out would not take out what they hold.
    private void Guard(ContentContext context, bool fill, bool stroke, PdfDictionary? optional)
    {
        var state = context.State;
        bool Risky(PdfColor color) =>
            (color.Pattern is not null || color.PatternName is not null) && !(color.Pattern is { } pattern && RedactionPatterns.Plain(context.Document, pattern));
        if (state.SoftMask is not null || fill && Risky(state.FillColor) || stroke && Risky(state.StrokeColor) || Conditional(context.Document, optional) || Conditional(context.Document, context.OptionalContent)) Unhandled = true;
    }

    // A layer that the file declares, is on and has no expression to decide shows what is there, and the shape goes like any other; the rest may hide it.
    private bool Conditional(PdfDocument document, PdfDictionary? group)
    {
        if (group is null) return false;
        _layers ??= new LayerVisibility(document);
        _declared ??= PdfLayers.Read(document).Layers.Select(l => document.Get(l.Reference.Number)).OfType<PdfDictionary>().ToHashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var members = document.Name(group, "Type") == "OCMD"
            ? (document.Resolve(group["OCGs"]) is PdfArray array ? array.Items.Select(document.Resolve) : [document.Resolve(group["OCGs"])]).OfType<PdfDictionary>().ToList()
            : [group];
        return document.Name(group, "Type") is not ("OCG" or "OCMD") || group.ContainsKey("VE") || _layers.IsHidden(group) || members.Any(m => !_declared.Contains(m));
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        bool paints = path.Fill || path.Stroke;
        if (!(paints || path.Clips)) return;
        if (path.Stroke) path = path with { InkBounds = Grown(path, context.State) };
        var hit = areas.Where(a => RedactionPaths.Meets(path, a)).ToList();
        if (hit.Count == 0)
        {
            if (paints) Count(context, false);
            return;
        }
        // A rectangle that only clips and holds every mark shows no shape; one with an edge inside a mark, or the clip of anything else, can be the marked shape itself.
        if (!paints && RedactionPaths.AxisRectangle(path) is { } clip && hit.All(a => Covers(clip, a.Bounds))) return;
        Count(context, true);
        Paths++;
        var state = context.State;
        if (paints) Guard(context, path.Fill, path.Stroke, null);
        List<List<(double X, double Y)>> remains = [];
        if (state.Ctm.Invert() is not null)
        {
            if (path.Clips) remains = RedactionPaths.Outside(path, hit);
            else if (path.Fill && !path.Stroke && state.FillColor.Pattern is null && state.FillColor.PatternName is null && state.SoftMask is null && RedactionPaths.AxisRectangle(path) is { } rect)
            {
                remains = RedactionPaths.Around(rect, hit);
            }
        }
        Current.Edits[context.OperatorIndex] = new PathEdit(path.Clips, state.Ctm, remains);
    }

    // A stroke reaches the width of the line times the largest stretch of the matrix, further at a miter join and past a square cap (8.4.3).
    private static PdfRect Grown(PathInfo path, GraphicsState state)
    {
        var m = state.Ctm;
        double sum = m.A * m.A + m.B * m.B + m.C * m.C + m.D * m.D, determinant = m.A * m.D - m.B * m.C;
        double stretch = Math.Sqrt((sum + Math.Sqrt(Math.Max(sum * sum - 4 * determinant * determinant, 0))) / 2);
        double join = state.LineJoin == 0 && path.Segments.Count > 2 ? Math.Max(state.MiterLimit, 1) : 1;
        double grow = Math.Max(state.LineWidth, 0) * stretch / 2 * Math.Max(join, Math.Sqrt(2));
        var b = path.Bounds;
        return new PdfRect(b.Left - grow, b.Bottom - grow, b.Right + grow, b.Top + grow);
    }

    public override void PaintImage(ContentContext context, ImageInfo image)
    {
        var square = Geometry.Corners(image.Matrix, 0, 0, 1, 1);
        var hit = areas.Where(a => Geometry.Overlaps(square, a)).ToList();
        if (hit.Count == 0)
        {
            Count(context, false);
            return;
        }
        Count(context, true);
        Images++;
        Guard(context, image.IsMask, false, image.OptionalContent);
        if (image.Stream is not { } stream)
        {
            Current.Edits[context.OperatorIndex] = DeleteEdit.Instance;
            return;
        }
        // The cut makes copies of the masks too, so a second holder of one still names the original.
        foreach (var held in ImageRedactor.Masks(context.Document, stream).Prepend(stream)) Edited[held] = Edited.GetValueOrDefault(held) + 1;
        Current.Edits[context.OperatorIndex] = new ImageEdit(stream, hit, image.Matrix);
    }

    public override void PaintShading(ContentContext context, ShadingInfo shading)
    {
        if (!areas.Any(a => Geometry.Meets(shading.Bounds, a))) return;
        var dictionary = shading.Shading as PdfDictionary ?? (shading.Shading as PdfStream)?.Dictionary;
        Guard(context, false, false, null);
        // Mesh and function shadings carry their samples in the file, and the clip hole hides them without removing them.
        if (dictionary is not null && context.Document.Integer(dictionary, "ShadingType") is 1 or >= 4)
        {
            Count(context, true);
            Paths++;
            Current.Edits[context.OperatorIndex] = DeleteEdit.Instance;
            return;
        }
        var inverse = context.State.Ctm.Invert();
        if (inverse is not { } back) return;
        Count(context, true);
        var everything = Geometry.Corners(back, -1e6, -1e6, 1e6, 1e6);
        var holes = areas.Select(a => a.Points.Select(p => back.Transform(p.X, p.Y)).ToList());
        var path = new StringBuilder("q\n");
        foreach (var polygon in holes.Prepend(everything)) RedactionPaths.Polygon(path, polygon);
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
        var child = new ScanNode(form.Stream);
        Current.Children[context.OperatorIndex] = child;
        _nodes.Push(child);
    }

    public override void EndForm(ContentContext context, FormInfo form)
    {
        var child = _nodes.Pop();
        if (!child.HasEdits) return;
        Edited[form.Stream] = Edited.GetValueOrDefault(form.Stream) + 1;
        if (Conditional(context.Document, form.OptionalContent)) Unhandled = true;
    }

    private static bool Covers(PdfRect outer, PdfRect inner) =>
        outer.Left <= inner.Left && outer.Bottom <= inner.Bottom && outer.Right >= inner.Right && outer.Top >= inner.Top;

    private void Count(ContentContext context, bool removed)
    {
        if (removed)
        {
            // A description of the text in a sequence that lost some of it would give it away.
            foreach (var (node, op, marked) in _open)
            {
                // Whatever else the properties hold, a description among it is not known to be free of the removed text; /OC is a layer and means nothing else.
                if (marked.Properties is not { } p || marked.Tag == "OC") continue;
                node.DirtyMarked[op] = p;
            }
        }
        // The structure tree names the sequences of the page itself; what a form paints belongs to the one that calls it.
        if (_open.FindLast(o => ReferenceEquals(o.Node, Root) && o.Marked.Mcid is not null) is not { Marked.Mcid: { } mcid }) return;
        var (total, gone) = Marked.GetValueOrDefault(mcid);
        Marked[mcid] = (total + 1, gone + (removed ? 1 : 0));
    }
}
