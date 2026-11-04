namespace LazyPDF.Core;

/// <summary>
/// Follows a page and everything it paints to the end, by the strictest reading, and records what it painted. A page
/// with marks is redacted in place only when this finds nothing it cannot account for: content that does not parse
/// whole, operators or operands outside <see cref="RedactionSyntax"/>, an inline image whose end is open to doubt,
/// a name a viewer may resolve differently, a form that reaches itself, limits the interpreter stops at without
/// saying so, and Type 3 glyphs that paint anything but shapes and bitmaps. What a viewer may draw from such
/// content is never looked at by the scan, so the page is flattened instead.
/// </summary>
internal sealed class RedactionWalk(PdfDocument document)
{
    /// <summary>The nesting at which the interpreter stops entering forms.</summary>
    public const int FormDepth = 20;

    private static readonly string[] FontKinds = ["Type1", "MMType1", "TrueType", "Type3", "Type0"];
    private static readonly string[] CidKinds = ["CIDFontType0", "CIDFontType2"];
    private static readonly HashSet<string> NotInText = new("q Q cm m l c v y h re S s f F f* B B* b b* n W W* sh Do BI d0 d1 BT".Split(' '));
    private static readonly HashSet<string> OnlyInText = new("Td TD Tm T* Tj TJ ' \"".Split(' '));
    private static readonly string[] DeviceSpaces = ["DeviceGray", "DeviceRGB", "DeviceCMYK"];

    private const int MaxStack = 256;
    private const int MaxMarked = 1024;
    private const long MaxSegments = 1_000_000;
    private const int MaxOperations = 1_000_000;
    private const long MaxEntered = 5_000_000;
    private const long MaxSize = 64L << 20;

    private sealed record Scope(PdfDictionary? Own, Scope? Outer)
    {
        public PdfDictionary? Effective => Own ?? Outer?.Effective;
    }

    private sealed record Body(int Operations, int Stack, int Marked, Dictionary<(string Category, string Name), int> Uses);

    private readonly Dictionary<PdfStream, Body> _bodies = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfStream, PdfDictionary?> _inherited = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _active = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfDictionary, bool> _fonts = new(ReferenceEqualityComparer.Instance);
    private long _entered;

    /// <summary>Why the walk gave up; null when it followed everything.</summary>
    public string? Problem { get; private set; }

    public bool Ok => Problem is null;

    /// <summary>The numbers of the objects that are painted: everything a used resource leads to.</summary>
    public HashSet<int> Used { get; } = [];

    /// <summary>The names the content found, as the list that holds them and the name: what a rebuilt resource dictionary keeps.</summary>
    public HashSet<(PdfDictionary List, string Name)> Reads { get; } = [];

    /// <summary>How many times each form, cell, mask group, picture or glyph procedure was entered, whichever way.</summary>
    public Dictionary<PdfStream, int> Entries { get; } = new(ReferenceEqualityComparer.Instance);

    /// <summary>Follows the page; <paramref name="content"/> is what the page is to show, when not what it holds now.</summary>
    public bool Page(PdfPage page, byte[]? content = null)
    {
        var scope = new Scope(page.Resources, null);
        Lists(page.Dictionary);
        var breaks = new List<int>();
        if ((content ?? Joined(page, breaks)) is { } data && Read(data, scope, breaks) is { } body) Follow(body, scope, 0, 0, 0, 1);
        return Ok;
    }

    /// <summary>Follows <paramref name="content"/> as the content of the form or cell <paramref name="owner"/>, with the resources it has now.</summary>
    public bool Content(PdfDictionary owner, byte[] content)
    {
        var scope = new Scope(document.Dict(owner, "Resources"), null);
        Lists(owner);
        if (Read(content, scope) is { } body) Follow(body, scope, 0, 0, 0, 1);
        return Ok;
    }

    // The streams are read one by one: a stream that does not read is content the page has and the walk has not seen.
    private byte[]? Joined(PdfPage page, List<int> breaks)
    {
        var joined = new MemoryStream();
        var contents = document.Resolve(page.Dictionary["Contents"]);
        int count = 0;
        foreach (var item in contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance])
        {
            var part = document.Resolve(item);
            if (part is null or PdfNull) continue;
            try
            {
                if (part is not PdfStream stream) throw PdfReadException.Damaged("Not a content stream.");
                var data = document.Data(stream, MaxSize - joined.Length);
                if (count++ > 0)
                {
                    breaks.Add((int)joined.Length);
                    joined.WriteByte((byte)'\n');
                }
                joined.Write(data);
            }
            catch (PdfReadException)
            {
                Fail("content stream does not read");
                return null;
            }
        }
        return joined.ToArray();
    }

    /// <summary>
    /// Follows what the page keeps of its annotations: the appearances they are drawn with, as forms. Annotations that were
    /// removed are no longer in the page. False when an appearance cannot be followed.
    /// </summary>
    public bool Annotations(PdfPage page)
    {
        if (page.Dictionary["Annots"] is not { } annots) return Ok;
        Keep(annots, RedactionObjects.Annotating);
        foreach (var item in document.Resolve(annots) is PdfArray array ? array.Items : [])
        {
            if (document.Dict(document.Resolve(item) as PdfDictionary, "AP") is not { } appearance) continue;
            foreach (string key in (ReadOnlySpan<string>)["N", "R", "D"])
            {
                var state = appearance[key];
                IEnumerable<PdfObject?> forms = document.Resolve(state) is PdfDictionary states ? states.Entries.Select(e => (PdfObject?)e.Value) : [state];
                foreach (var form in forms)
                {
                    if (form is not null && document.Resolve(form) is PdfStream stream) Enter(form, stream, new Scope(null, null), 0, 0, 0, 1);
                }
            }
        }
        return Ok;
    }

    // The resource dictionary and its lists are objects of their own when they are indirect, and stay with the names in them.
    // Only the lists of 7.8.3 are looked at, and each has to be a dictionary of its own: any other value there is not a list.
    private void Lists(PdfDictionary owner)
    {
        var resources = document.Resolve(owner["Resources"]);
        if (resources is not (null or PdfNull or PdfDictionary) || RedactionObjects.InTree(document, resources))
        {
            Fail("resources");
            return;
        }
        if (owner["Resources"] is PdfReference own) Used.Add(own.Number);
        foreach (string category in RedactionResources.Lists)
        {
            if (document.Resolve(((PdfDictionary?)resources)?[category]) is not { } list) continue;
            if (list is not PdfDictionary || RedactionObjects.InTree(document, list))
            {
                Fail("resource list");
                return;
            }
            if (((PdfDictionary)resources!)[category] is PdfReference reference) Used.Add(reference.Number);
        }
    }

    private void Fail(string problem) => Problem ??= problem;

    private Body? Read(byte[] data, Scope scope, IReadOnlyList<int>? breaks = null)
    {
        IReadOnlyList<ContentOperation> operations;
        try
        {
            operations = ContentParser.Parse(data);
        }
        catch (PdfReadException)
        {
            Fail("content does not parse");
            return null;
        }
        if (operations.Count > MaxOperations)
        {
            Fail("too many operations");
            return null;
        }
        if (!RedactionSyntax.Whole(data, operations, breaks))
        {
            Fail("content is not well formed");
            return null;
        }
        // A pattern name only means something in a pattern space; the interpreter ignores it elsewhere and a viewer may not.
        bool text = false, fill = false, stroke = false;
        var saved = new Stack<(bool Fill, bool Stroke)>();
        int stack = 0, deepest = 0, marked = 0, markedDeepest = 0;
        long segments = 0;
        var uses = RedactionSyntax.Defaults.ToDictionary(d => d, _ => 1);
        foreach (var op in operations)
        {
            if (!RedactionSyntax.Valid(op))
            {
                Fail($"operator {op.Operator}");
                return null;
            }
            // Figure 9 of ISO 32000-1: a text object holds text, colour and state operators and nothing that draws elsewhere.
            if (text && NotInText.Contains(op.Operator) || !text && (OnlyInText.Contains(op.Operator) || op.Operator == "ET"))
            {
                Fail("operator outside its object");
                return null;
            }
            switch (op.Operator)
            {
                case "BT": text = true; break;
                case "ET": text = false; break;
                case "cs": fill = IsPattern(scope, op.Operands[0]); break;
                case "CS": stroke = IsPattern(scope, op.Operands[0]); break;
                case "g" or "rg" or "k": fill = false; break;
                case "G" or "RG" or "K": stroke = false; break;
                case "scn" when op.Operands[^1] is PdfName && !fill:
                case "SCN" when op.Operands[^1] is PdfName && !stroke:
                    Fail("pattern name outside a pattern space");
                    return null;
                case "q":
                    saved.Push((fill, stroke));
                    deepest = Math.Max(deepest, ++stack);
                    break;
                case "Q" when stack == 0: Fail("Q without q"); return null;
                case "Q": stack--; (fill, stroke) = saved.Pop(); break;
                case "BMC" or "BDC": markedDeepest = Math.Max(markedDeepest, ++marked); break;
                case "EMC": marked = Math.Max(0, marked - 1); break;
                case "m" or "l" or "c" or "v" or "y" or "h": segments++; break;
                case "re": segments += 5; break;
                case "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "n": segments = 0; break;
                case "BI" when !RedactionSyntax.Fits(document, op, data, name => Find(scope, "ColorSpace", name)):
                    Fail("inline image");
                    return null;
            }
            if (segments > MaxSegments)
            {
                Fail("path too long");
                return null;
            }
            foreach (var use in RedactionSyntax.Names(op)) uses[use] = uses.GetValueOrDefault(use) + 1;
        }
        return new Body(operations.Count, deepest, markedDeepest, uses);
    }

    // An uncoloured tiling pattern needs a space of its own, [/Pattern /DeviceRGB] under a name (8.7.3.3).
    private bool IsPattern(Scope scope, PdfObject operand) =>
        operand is PdfName { Value: var name } && (name == "Pattern"
            || !DeviceSpaces.Contains(name) && document.Resolve(Find(scope, "ColorSpace", name)) is PdfArray { Items: [var first, ..] } && document.Resolve(first) is PdfName { Value: "Pattern" });

    // An entry only an enclosing list has is one the interpreter finds and a viewer may not.
    private PdfObject? Find(Scope scope, string category, string name)
    {
        if (document.Dict(scope.Effective, category) is { } list && list[name] is { } found)
        {
            Reads.Add((list, name));
            return found;
        }
        for (var outer = scope; outer is not null; outer = outer.Outer)
        {
            if (document.Dict(outer.Own, category)?[name] is not { } borrowed) continue;
            Fail("name resolved in an enclosing list");
            return borrowed;
        }
        return null;
    }

    private void Follow(Body body, Scope scope, int depth, int stack, int marked, long times)
    {
        _entered += body.Operations * times;
        if (_entered > MaxEntered)
        {
            Fail("too much content");
            return;
        }
        if (stack + body.Stack > MaxStack || marked + body.Marked > MaxMarked)
        {
            Fail("nesting");
            return;
        }
        foreach (var ((category, name), count) in body.Uses)
        {
            if (Problem is not null) return;
            if (Find(scope, category, name) is { } raw) Use(raw, category, scope, depth, stack + body.Stack, marked + body.Marked, Math.Min(times * count, MaxEntered));
        }
    }

    private void Use(PdfObject raw, string category, Scope scope, int depth, int stack, int marked, long times)
    {
        switch (category, document.Resolve(raw))
        {
            case ("XObject", PdfStream x) when document.Name(x.Dictionary, "Subtype") == "Image":
                RedactionObjects.PaintedStream(document, raw, Used, RedactionObjects.Painting);
                Count(x, times);
                foreach (var mask in ImageRedactor.Masks(document, x)) Count(mask, times);
                break;
            case ("XObject", PdfStream x) when document.Name(x.Dictionary, "Subtype") == "Form":
                Enter(raw, x, scope, depth, stack, marked, times);
                break;
            case ("XObject", not null):
                Fail("xobject kind");
                break;
            case ("Font", PdfDictionary font):
                Font(raw, font);
                break;
            case ("ExtGState", PdfDictionary state):
                State(raw, state, scope, depth, stack, marked, times);
                break;
            case ("Pattern", PdfStream cell) when document.Integer(cell.Dictionary, "PatternType") == 1:
                Enter(raw, cell, scope, depth, stack, marked, times);
                break;
            case ("Pattern", PdfDictionary shading) when document.Integer(shading, "PatternType") == 2 && RedactionSyntax.IsMatrix(document, shading, "Matrix"):
                Keep(raw, "ExtGState");
                if (document.Resolve(shading["ExtGState"]) is PdfDictionary through) State(shading["ExtGState"]!, through, scope, depth, stack, marked, times);
                break;
            case ("Pattern", not null):
                Fail("pattern kind");
                break;
            case ("Shading", PdfStream mesh) when !RedactionObjects.Barred(document, mesh):
                RedactionObjects.PaintedStream(document, raw, Used, RedactionObjects.Painting);
                break;
            case ("Shading", PdfDictionary):
            case ("ColorSpace" or "Properties", PdfDictionary or PdfArray or PdfName):
                Keep(raw);
                break;
            case ("Shading" or "ColorSpace" or "Properties", PdfStream):
                Fail("resource kind");
                break;
        }
    }

    private void State(PdfObject raw, PdfDictionary state, Scope scope, int depth, int stack, int marked, long times)
    {
        // A font chosen by a graphics state is a way back into Type 3 procedures that no operator names.
        if (state.ContainsKey("Font"))
        {
            Fail("graphics state font");
            return;
        }
        Keep(raw, "SMask");
        if (document.Resolve(state["SMask"]) is PdfDictionary mask)
        {
            Keep(state["SMask"]!, "G");
            if (mask["G"] is { } group && document.Resolve(group) is PdfStream groupStream) Enter(group, groupStream, scope, depth, stack, marked, times);
            else Fail("soft mask group");
        }
    }

    private void Enter(PdfObject raw, PdfStream stream, Scope scope, int depth, int stack, int marked, long times)
    {
        RedactionObjects.PaintedStream(document, raw, Used, RedactionObjects.Painting, "Resources");
        if (!RedactionSyntax.IsMatrix(document, stream.Dictionary, "Matrix"))
        {
            Fail("matrix");
            return;
        }
        if (depth >= FormDepth)
        {
            Fail("form depth");
            return;
        }
        if (!_active.Add(stream))
        {
            Fail("form reaches itself");
            return;
        }
        Count(stream, times);
        Lists(stream.Dictionary);
        var inner = new Scope(document.Dict(stream.Dictionary, "Resources"), scope);
        if (_bodies.TryGetValue(stream, out var body))
        {
            // Without resources of its own the form takes the enclosing ones, so a second place that has others is another reading.
            if (inner.Own is null && !ReferenceEquals(_inherited[stream], inner.Effective)) Fail("form inherits different resources");
        }
        else
        {
            byte[]? data = null;
            try
            {
                data = document.Data(stream, MaxSize);
            }
            catch (PdfReadException)
            {
                Fail("form does not read");
            }
            _inherited[stream] = inner.Effective;
            body = data is null ? null : Read(data, inner);
            if (body is not null) _bodies[stream] = body;
        }
        if (body is not null && Problem is null) Follow(body, inner, depth + 1, stack, marked, times);
        _active.Remove(stream);
    }

    private void Font(PdfObject raw, PdfDictionary font)
    {
        Keep(raw, "Resources");
        // A font PdfFont reads one way and a viewer another (a composite one by its descendants, a simple one by its codes) is not followed.
        string kind = document.Name(font, "Subtype") ?? "";
        bool composite = kind == "Type0";
        if (!FontKinds.Contains(kind) || composite != font.ContainsKey("DescendantFonts")
            || composite && !(document.Array(font, "DescendantFonts") is { Items: [var descendant] } && CidKinds.Contains(document.Name(document.Resolve(descendant) as PdfDictionary, "Subtype") ?? "")))
        {
            Fail("font kind");
            return;
        }
        if (!RedactionGlyphs.Measured(document, font)) Fail("font metrics");
        if (kind != "Type3") return;
        if (!_fonts.TryGetValue(font, out bool plain)) _fonts[font] = plain = RedactionGlyphs.Plain(document, font);
        if (!plain) Fail("Type 3 glyphs");
    }

    private void Count(PdfStream stream, long times) => Entries[stream] = (int)Math.Min(Entries.GetValueOrDefault(stream) + times, MaxEntered);

    // What the object leads to by the keys of RedactionObjects.Painting is painted with it, except the keys given, which the walk follows by what the content names.
    private void Keep(PdfObject raw, params string[] apart) => RedactionObjects.Painted(document, raw, Used, RedactionObjects.Painting, apart);

    private void Keep(PdfObject raw, RedactionObjects.Reading reading) => RedactionObjects.Painted(document, raw, Used, reading);
}
