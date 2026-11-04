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
    public HashSet<int> DirtyMarked { get; } = [];

    public bool HasEdits => Edits.Count > 0 || DirtyMarked.Count > 0 || Children.Values.Any(c => c.HasEdits);
}

/// <summary>
/// Walks a page and records what meets the marks, per content stream and operator index: glyphs,
/// paths, images, shadings and the marked content that held them.
/// </summary>
internal sealed class RedactionScan(IReadOnlyList<MarkArea> areas, PdfDictionary? pageResources = null) : ContentVisitor
{
    private static readonly string[] AltKeys = ["ActualText", "Alt", "E"];
    private const int MaxFormDepth = 20;

    private readonly Stack<ScanNode> _nodes = new([new ScanNode(null)]);
    private readonly List<(ScanNode Node, int Op, MarkedContent Marked)> _open = [];
    private readonly Dictionary<PdfStream, string[]?> _calls = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfStream, bool> _followable = new(ReferenceEqualityComparer.Instance);
    private int _pattern;

    public ScanNode Root => _nodes.Last();
    public int Glyphs { get; private set; }
    public int Images { get; private set; }
    public int Paths { get; private set; }

    /// <summary>A form that could not be run to its end meets a mark, so what it holds was not looked at.</summary>
    public bool Incomplete { get; private set; }

    /// <summary>What painted under a mark, so that it can be dropped from the resources if nothing else paints it: fonts, patterns, shadings, soft masks and property lists.</summary>
    public HashSet<object> Dropped { get; } = new(ReferenceEqualityComparer.Instance);

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
        Dropped.Add(glyph.Font.Dictionary);
        if (glyph.Font.IsType3) RedactionPrune.Glyph(context.Document, glyph.Font, context.Forms.Count > 0 ? context.Document.Dict(context.Forms[^1].Dictionary, "Resources") : pageResources, glyph.Code, Dropped);
        RedactionPrune.Note(o => Dropped.Add(o), state, state.RenderMode is 0 or 2 or 4 or 6, state.RenderMode is 1 or 2 or 5 or 6);
        double scale = glyph.Font.IsVertical ? state.FontSize : state.FontSize * state.HorizontalScale;
        double adjust = scale == 0 ? 0 : -glyph.Advance * 1000 / scale;
        if (!Current.Edits.TryGetValue(context.OperatorIndex, out var edit)) Current.Edits[context.OperatorIndex] = edit = new TextEdit([]);
        ((TextEdit)edit).Removed[(glyph.Element, glyph.Offset)] = (glyph.Character.Length, adjust);
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        bool paints = path.Fill || path.Stroke;
        if (_pattern > 0 || !(paints || path.Clips)) return;
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
        RedactionPrune.Note(o => Dropped.Add(o), state, path.Fill, path.Stroke);
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
        RedactionPrune.Note(o => Dropped.Add(o), context.State, image.IsMask, false);
        Current.Edits[context.OperatorIndex] = image.Stream is { } stream ? new ImageEdit(stream, hit, image.Matrix) : DeleteEdit.Instance;
    }

    public override void PaintShading(ContentContext context, ShadingInfo shading)
    {
        if (_pattern > 0 || !areas.Any(a => Geometry.Meets(shading.Bounds, a))) return;
        var dictionary = shading.Shading as PdfDictionary ?? (shading.Shading as PdfStream)?.Dictionary;
        // Mesh and function shadings carry their samples in the file, and the clip hole hides them without removing them.
        if (dictionary is not null && context.Document.Integer(dictionary, "ShadingType") is 1 or >= 4)
        {
            Count(context, true);
            Paths++;
            Dropped.Add(shading.Shading);
            RedactionPrune.Note(o => Dropped.Add(o), context.State, false, false);
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
        // The interpreter does not enter forms below this depth, nor read one that fails or is too long, and it skips
        // a form that is already running. What such a form holds cannot be looked at, so a use of it that reaches a
        // mark goes whole.
        if (!form.IsPattern && (context.Forms.Count >= MaxFormDepth || !Followable(context, form.Stream)) && areas.Any(a => Geometry.Meets(form.Bounds, a)))
        {
            Incomplete = true;
            Count(context, true);
            Paths++;
            Dropped.Add(form.Stream);
            Current.Edits[context.OperatorIndex] = DeleteEdit.Instance;
        }
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

    private bool Followable(ContentContext context, PdfStream form)
    {
        if (_followable.TryGetValue(form, out bool known)) return known;
        var scope = new List<PdfDictionary?>([pageResources, .. context.Forms.Select(f => context.Document.Dict(f.Dictionary, "Resources"))]);
        known = Calls(context.Document, form) is not null && !Reaches(context.Document, form, form, scope, new(ReferenceEqualityComparer.Instance), 0);
        _followable[form] = known;
        return known;
    }

    // The names a form paints with Do; null when it cannot be read.
    private string[]? Calls(PdfDocument document, PdfStream form)
    {
        if (_calls.TryGetValue(form, out var known)) return known;
        known = RedactionLimits.Followable(document, form)?.Where(o => o.Operator == "Do" && o.Operands.FirstOrDefault() is PdfName)
            .Select(o => ((PdfName)o.Operands[0]).Value).Distinct().ToArray();
        _calls[form] = known;
        return known;
    }

    // Whether the form paints, through the forms it calls, the one it started from. The interpreter looks a name up
    // in the innermost resources first, then in those of the forms that call.
    private bool Reaches(PdfDocument document, PdfStream at, PdfStream target, List<PdfDictionary?> scope, Dictionary<object, int> seen, int depth)
    {
        if (depth >= MaxFormDepth || seen.TryGetValue(at, out int shallowest) && shallowest <= depth) return false;
        seen[at] = depth;
        scope = [.. scope, document.Dict(at.Dictionary, "Resources")];
        foreach (string name in Calls(document, at) ?? [])
        {
            var found = scope.AsEnumerable().Reverse().Select(r => document.Dict(r, "XObject")).FirstOrDefault(x => x is not null && x.ContainsKey(name));
            if (document.Resolve(found?[name]) is not PdfStream called) continue;
            if (ReferenceEquals(called, target) || Reaches(document, called, target, scope, seen, depth + 1)) return true;
        }
        return false;
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
                if (marked.Properties is not { } p || !AltKeys.Any(p.ContainsKey)) continue;
                node.DirtyMarked.Add(op);
                Dropped.Add(p);
            }
        }
        // The structure tree names the sequences of the page itself; what a form paints belongs to the one that calls it.
        if (_open.FindLast(o => ReferenceEquals(o.Node, Root) && o.Marked.Mcid is not null) is not { Marked.Mcid: { } mcid }) return;
        var (total, gone) = Marked.GetValueOrDefault(mcid);
        Marked[mcid] = (total + 1, gone + (removed ? 1 : 0));
    }
}
