namespace LazyPDF.Core;

/// <summary>
/// Takes out of every resource dictionary of the file what was only painted by content that was
/// removed: pictures, forms, patterns, shadings, fonts, property lists and the soft masks of graphics
/// states. A name that stays listed keeps its object in the file whether anything paints it or not.
/// Only objects that painted under a mark are looked at; the rest of the file is not touched.
/// A pattern cell or mask group that still has other uses cannot be cut by a mark, since it is drawn
/// everywhere it is used; when it holds pictures or text it is emptied for all of them, and what the
/// emptied cell painted no longer counts as painted.
/// </summary>
internal static class RedactionPrune
{
    private const int MaxDepth = 32;
    private const int MaxGroups = 64;
    private static readonly string[] Categories = ["XObject", "Pattern", "Shading", "Font", "Properties"];

    /// <summary>Adds what a paint with the state uses besides its own geometry: the patterns it is filled or stroked with and the soft mask.</summary>
    public static void Note(Action<object> use, GraphicsState state, bool fill, bool stroke)
    {
        if (fill && state.FillColor.Pattern is { } filled) use(filled);
        if (stroke && state.StrokeColor.Pattern is { } stroked) use(stroked);
        if (state.SoftMask is { } mask) use(mask);
    }

    /// <summary>The procedure of a glyph taken out of a Type 3 font, and what it paints: all of it goes unless something else paints it.</summary>
    public static void Glyph(PdfDocument document, PdfFont font, PdfDictionary? inherited, int code, HashSet<object> dropped)
    {
        if (Procedure(document, font, code) is not { } procedure || !dropped.Add(procedure) || Runnable(document, font.Dictionary, procedure, inherited) is not { } run) return;
        var painted = new Painted(document, []) { Resources = inherited };
        var interpreter = new ContentInterpreter(document) { WalkPatterns = false };
        interpreter.Run(run, painted);
        while (painted.Later.TryDequeue(out var more)) interpreter.Run(more, painted);
        dropped.UnionWith(painted.Used);
    }

    /// <returns>What was found unused and taken out of the resource lists; <see cref="Scrub"/> takes it out of the other references.</returns>
    public static HashSet<object> Run(PdfDocument document, HashSet<object> dropped)
    {
        if (dropped.Count == 0) return [];
        var painted = Paint(document, []);
        var emptied = dropped.Where(o => painted.Used.Contains(o) && Carries(document, o)).ToHashSet(ReferenceEqualityComparer.Instance);
        if (emptied.Count > 0) painted = Paint(document, emptied);

        var gone = dropped.Where(o => !painted.Used.Contains(o)).ToHashSet(ReferenceEqualityComparer.Instance);
        if (gone.Count == 0 && emptied.Count == 0) return gone;

        var standIns = new StandIns(document);
        var visited = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (int number in document.ObjectNumbers)
        {
            foreach (var holder in Direct(document.Get(number), 0).ToList())
            {
                if (document.Dict(holder, "Resources") is { } resources && visited.Add(resources)) Prune(document, resources, gone, emptied, standIns);
            }
        }
        if (document.Dict(document.Dict(document.Catalog, "AcroForm"), "DR") is { } defaults && visited.Add(defaults)) Prune(document, defaults, gone, emptied, standIns);
        return gone;
    }

    /// <summary>Takes the references to what went out of every object that still names it: alternates of a picture, glyph procedures, attached files.</summary>
    public static void Scrub(PdfDocument document, HashSet<object> gone)
    {
        if (gone.Count == 0) return;
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is { } value) Scrub(document, value, gone, 0);
        }
    }

    private static void Scrub(PdfDocument document, PdfObject value, HashSet<object> gone, int depth)
    {
        if (depth > MaxDepth) return;
        bool Left(PdfObject item) => item is PdfReference && document.Resolve(item) is { } target && gone.Contains(target);
        switch (value)
        {
            case PdfStream stream:
                Scrub(document, stream.Dictionary, gone, depth);
                break;
            case PdfDictionary dictionary:
                foreach (var (key, item) in dictionary.Entries.ToList())
                {
                    if (Left(item)) dictionary.Remove(key);
                    else Scrub(document, item, gone, depth + 1);
                }
                break;
            case PdfArray array:
                array.Items.RemoveAll(Left);
                foreach (var item in array.Items) Scrub(document, item, gone, depth + 1);
                break;
        }
    }

    // Every dictionary held directly in the object; what a reference leads to is an object of its own.
    private static IEnumerable<PdfDictionary> Direct(PdfObject? value, int depth)
    {
        if (depth > MaxDepth) yield break;
        switch (value)
        {
            case PdfStream stream:
                foreach (var inner in Direct(stream.Dictionary, depth)) yield return inner;
                break;
            case PdfDictionary dictionary:
                yield return dictionary;
                foreach (var (_, item) in dictionary.Entries)
                {
                    foreach (var inner in Direct(item, depth + 1)) yield return inner;
                }
                break;
            case PdfArray array:
                foreach (var item in array.Items)
                {
                    foreach (var inner in Direct(item, depth + 1)) yield return inner;
                }
                break;
        }
    }

    private static Painted Paint(PdfDocument document, HashSet<object> emptied)
    {
        var painted = new Painted(document, emptied);
        var interpreter = new ContentInterpreter(document) { WalkPatterns = false };
        bool truncated = false;
        void Walk(PdfStream form)
        {
            interpreter.Run(form, painted);
            truncated |= interpreter.IsTruncated;
        }
        foreach (var page in document.Pages)
        {
            painted.Resources = page.Resources;
            interpreter.Run(page, painted);
            truncated |= interpreter.IsTruncated;
            foreach (var form in Appearances(document, page)) Walk(form);
        }
        while (painted.Later.TryDequeue(out var cell)) Walk(cell);
        // What is painted is not known, so nothing can be said to be unused.
        if (truncated) throw new InvalidOperationException(RedactionText.TooBig);
        return painted;
    }

    // Every state of every appearance can be shown, not only the one selected.
    private static IEnumerable<PdfStream> Appearances(PdfDocument document, PdfPage page)
    {
        foreach (var item in document.Array(page.Dictionary, "Annots")?.Items ?? [])
        {
            if (document.Resolve(item) is not PdfDictionary annotation || document.Dict(annotation, "AP") is not { } appearance) continue;
            foreach (string key in new[] { "N", "D", "R" })
            {
                switch (document.Resolve(appearance[key]))
                {
                    case PdfStream stream:
                        yield return stream;
                        break;
                    case PdfDictionary states:
                        foreach (var (_, value) in states.Entries)
                        {
                            if (document.Resolve(value) is PdfStream state) yield return state;
                        }
                        break;
                }
            }
        }
    }

    private static PdfStream? Procedure(PdfDocument document, PdfFont font, int code) =>
        font.GlyphNameOf(code) is { } name && document.Dict(font.Dictionary, "CharProcs") is { } procedures ? document.Resolve(procedures[name]) as PdfStream : null;

    // A procedure is run as a form with the resources of its font (9.6.5), or the ones it is painted from when the font has none.
    private static PdfStream? Runnable(PdfDocument document, PdfDictionary font, PdfStream procedure, PdfDictionary? inherited)
    {
        try
        {
            var dictionary = procedure.Dictionary.Copy();
            dictionary.Remove("Filter");
            dictionary.Remove("DecodeParms");
            if ((document.Dict(font, "Resources") ?? inherited) is { } resources) dictionary["Resources"] = resources;
            return new PdfStream(dictionary, document.Data(procedure));
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private static PdfStream? Cell(PdfDocument document, object value) => value switch
    {
        PdfStream { Dictionary: var d } pattern when document.Integer(d, "PatternType") == 1 => pattern,
        PdfDictionary d => document.Resolve(d["G"]) as PdfStream,
        _ => null,
    };

    // Whether emptying the object takes pictures or text out of the file: what its content paints, what it paints
    // through soft masks, and the samples of a shading pattern. Content that cannot be read may hold anything.
    private static bool Carries(PdfDocument document, object value)
    {
        if (value is PdfDictionary shaded && document.Integer(shaded, "PatternType") == 2) return Samples(document, shaded["Shading"]);
        if (Cell(document, value) is not { } cell) return false;
        var carrier = new Carrier(document);
        carrier.Groups.Enqueue(cell);
        var interpreter = new ContentInterpreter(document);
        for (int runs = 0; !carrier.Found && carrier.Groups.TryDequeue(out var stream); runs++)
        {
            if (runs >= MaxGroups) return true;
            interpreter.Run(stream, carrier);
            if (interpreter.IsTruncated) return true;
        }
        return carrier.Found;
    }

    // Mesh and function shadings keep their samples in the file.
    private static bool Samples(PdfDocument document, PdfObject? shading) =>
        document.Resolve(shading) switch { PdfDictionary d => d, PdfStream s => s.Dictionary, _ => null } is { } dictionary && document.Integer(dictionary, "ShadingType") is 1 or >= 4;

    private static void Prune(PdfDocument document, PdfDictionary resources, HashSet<object> gone, HashSet<object> emptied, StandIns standIns)
    {
        foreach (string name in Categories)
        {
            if (document.Dict(resources, name) is not { } category) continue;
            foreach (var (key, value) in category.Entries.ToList())
            {
                if (document.Resolve(value) is not { } target) continue;
                if (gone.Contains(target))
                {
                    // A colour or font operator may still name it, and a name that is not there is an error to readers.
                    if (name == "Pattern") category[key] = standIns.Pattern;
                    else if (name == "Font") category[key] = standIns.Font;
                    else category.Remove(key);
                }
                else if (name == "Pattern" && emptied.Contains(target)) category[key] = standIns.Pattern;
            }
        }
        if (document.Dict(resources, "ExtGState") is not { } states) return;
        foreach (var (_, value) in states.Entries)
        {
            if (document.Resolve(value) is not PdfDictionary state) continue;
            if (document.Resolve(state["SMask"]) is { } mask)
            {
                if (gone.Contains(mask)) state.Remove("SMask");
                else if (emptied.Contains(mask)) state["SMask"] = standIns.Mask;
            }
            if (document.Array(state, "Font")?.Items is [var font, ..] && document.Resolve(font) is { } used && gone.Contains(used)) state.Remove("Font");
        }
    }

    // What takes the place of an object that cannot go from a resource list: nothing visible, and no data.
    private sealed class StandIns(PdfDocument document)
    {
        private readonly Lazy<PdfReference> _pattern = new(() => document.Add(new PdfStream(new PdfDictionary
        {
            ["PatternType"] = new PdfNumber(1),
            ["PaintType"] = new PdfNumber(1),
            ["TilingType"] = new PdfNumber(1),
            ["BBox"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(1), new PdfNumber(1)]),
            ["XStep"] = new PdfNumber(1),
            ["YStep"] = new PdfNumber(1),
            ["Resources"] = new PdfDictionary(),
        }, [])));

        private readonly Lazy<PdfReference> _font = new(() => document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Font"),
            ["Subtype"] = new PdfName("Type1"),
            ["BaseFont"] = new PdfName("Helvetica"),
        }));

        private readonly Lazy<PdfReference> _mask = new(() => document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Mask"),
            ["S"] = new PdfName("Alpha"),
            ["G"] = document.Add(new PdfStream(new PdfDictionary
            {
                ["Type"] = new PdfName("XObject"),
                ["Subtype"] = new PdfName("Form"),
                ["BBox"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(1), new PdfNumber(1)]),
                ["Group"] = new PdfDictionary { ["S"] = new PdfName("Transparency") },
            }, [])),
        }));

        public PdfReference Pattern => _pattern.Value;
        public PdfReference Font => _font.Value;
        public PdfReference Mask => _mask.Value;
    }

    private sealed class Carrier(PdfDocument document) : ContentVisitor
    {
        private readonly HashSet<PdfStream> _seen = new(ReferenceEqualityComparer.Instance);

        public bool Found { get; private set; }

        /// <summary>Soft mask groups met on the way, which the interpreter does not enter.</summary>
        public Queue<PdfStream> Groups { get; } = [];

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => Found = true;

        public override void PaintImage(ContentContext context, ImageInfo image) => Found = true;

        public override void PaintPath(ContentContext context, PathInfo path) => Through(context.State, path.Fill, path.Stroke);

        public override void PaintShading(ContentContext context, ShadingInfo shading)
        {
            Found |= Samples(document, shading.Shading);
            Through(context.State, false, false);
        }

        public override void BeginForm(ContentContext context, FormInfo form) => Found |= RedactionLimits.Followable(document, form.Stream) is null;

        private void Through(GraphicsState state, bool fill, bool stroke)
        {
            if (state.SoftMask is { } mask && document.Resolve(mask["G"]) is PdfStream group && _seen.Add(group)) Groups.Enqueue(group);
            if (fill && state.FillColor.Pattern is PdfDictionary f && document.Integer(f, "PatternType") == 2) Found |= Samples(document, f["Shading"]);
            if (stroke && state.StrokeColor.Pattern is PdfDictionary s && document.Integer(s, "PatternType") == 2) Found |= Samples(document, s["Shading"]);
        }
    }

    private sealed class Painted(PdfDocument document, HashSet<object> emptied) : ContentVisitor
    {
        private readonly HashSet<PdfDictionary> _everything = new(ReferenceEqualityComparer.Instance);

        public HashSet<object> Used { get; } = new(ReferenceEqualityComparer.Instance);

        /// <summary>Content that the interpreter does not enter by itself: pattern cells of text, mask groups, glyph procedures of Type 3 fonts.</summary>
        public Queue<PdfStream> Later { get; } = [];

        /// <summary>The resources of the page being walked, for glyph procedures of a font that has none.</summary>
        public PdfDictionary? Resources { get; set; }

        // The content of a cell that was emptied is not painted any more.
        private void Use(object value)
        {
            if (!Used.Add(value)) return;
            switch (value)
            {
                case PdfStream { Dictionary: var d } pattern when document.Integer(d, "PatternType") == 1:
                    if (!emptied.Contains(pattern)) Later.Enqueue(pattern);
                    break;
                case PdfDictionary d when document.Integer(d, "PatternType") == 2:
                    if (!emptied.Contains(d) && document.Resolve(d["Shading"]) is { } shading) Used.Add(shading);
                    break;
                case PdfDictionary d when document.Resolve(d["G"]) is PdfStream group:
                    if (!emptied.Contains(d)) Later.Enqueue(group);
                    break;
            }
        }

        // The procedure of the glyph, or all of them when the code has no name to find it by.
        private void UseProcedure(PdfFont font, int code)
        {
            if (Procedure(document, font, code) is { } procedure)
            {
                if (Used.Add(procedure) && Runnable(document, font.Dictionary, procedure, Resources) is { } run) Later.Enqueue(run);
                return;
            }
            if (!_everything.Add(font.Dictionary) || document.Dict(font.Dictionary, "CharProcs") is not { } procedures) return;
            foreach (var (_, value) in procedures.Entries)
            {
                if (document.Resolve(value) is PdfStream other && Used.Add(other) && Runnable(document, font.Dictionary, other, Resources) is { } run) Later.Enqueue(run);
            }
        }

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            var state = context.State;
            Use(glyph.Font.Dictionary);
            if (glyph.Font.IsType3) UseProcedure(glyph.Font, glyph.Code);
            Note(Use, state, state.RenderMode is 0 or 2 or 4 or 6, state.RenderMode is 1 or 2 or 5 or 6);
        }

        public override void PaintPath(ContentContext context, PathInfo path) => Note(Use, context.State, path.Fill, path.Stroke);

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (image.Stream is { } stream) Use(stream);
            Note(Use, context.State, image.IsMask, false);
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading)
        {
            Use(shading.Shading);
            Note(Use, context.State, false, false);
        }

        public override void BeginMarked(ContentContext context, MarkedContent marked)
        {
            if (marked.Properties is { } properties) Use(properties);
        }

        public override void BeginForm(ContentContext context, FormInfo form) => Use(form.Stream);
    }
}
