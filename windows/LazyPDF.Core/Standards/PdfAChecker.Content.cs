namespace LazyPDF.Core;

// Pages as drawn: content stream operators, colour, transparency, images, forms and fonts in use.
// The interpreter walks each page and enters forms and patterns; resource dictionaries are scanned
// as well, so a graphics state or image that is defined but not yet painted is held to the same rules,
// though only what is painted counts as a use of a device colour space.
internal sealed partial class PdfAChecker
{
    private static readonly HashSet<string> Operators =
    [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI", "EMC", "ET", "EX",
        "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
        "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w",
        "W", "W*", "y", "'", "\"",
    ];

    private static readonly HashSet<string> BlendModes =
    [
        "Normal", "Compatible", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "ColorDodge", "ColorBurn", "HardLight", "SoftLight",
        "Difference", "Exclusion", "Hue", "Saturation", "Color", "Luminosity",
    ];

    private const int MaxScanDepth = 32;
    private const int MaxFontCodes = 70_000;
    private const int MaxOperations = 10_000_000;

    private const long MaxStreamBytes = 64L << 20;

    // The interpreter's limits on a form: the most operations it runs, how deep forms nest, and how many it keeps parsed. It skips a longer or
    // deeper form without a trace, and inflates a form that did not fit in its cache again at every paint.
    private const int MaxFormOperations = 1_000_000;
    private const int MaxFormDepth = 20;
    private const int MaxCachedForms = 1024;
    private const long MaxCachedOperations = 4_000_000;

    private readonly record struct FormCost(int Operations, long Size, bool Nests);

    private static readonly string[] RenderingIntents = ["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"];

    private readonly HashSet<PdfDictionary> _resourcesSeen = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _streamsSeen = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<(string Family, string Where, PdfDictionary? Scope)> _deviceUses = [];
    private readonly Dictionary<PdfStream, FormCost> _formCosts = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _cachedForms = new(ReferenceEqualityComparer.Instance);
    private long _cachedOperations;
    private readonly HashSet<PdfDictionary> _renderedFonts = new(ReferenceEqualityComparer.Instance);

    // Bytes of content read and operations run, all pages, forms and appearances together; the interpreter limits one run only.
    private long _work;
    private readonly Dictionary<string, string> _separations = [];
    private int _scanDepth;

    /// <summary>Colour components of the output intent's profile; 0 when the file has none.</summary>
    private int _intentComponents;

    private string ClauseImages => C("6.2.4", "6.2.8");
    private string ClauseForms => C("6.2.5", "6.2.9");
    private string ClauseReference => C("6.2.6", "6.2.9");
    private string ClausePostScript => C("6.2.7", "6.2.9");
    private string ClauseTransparency => C("6.4", "6.2.10");
    private string ClauseState => C("6.2.8", "6.2.5");
    private string ClauseIntent => C("6.2.9", "6.2.6");

    internal long MaxWork { get; init; } = 1L << 30;

    private bool OverBudget => _work > MaxWork;

    private void CheckPages()
    {
        var interpreter = new ContentInterpreter(_doc);
        var pages = _doc.Pages;
        int i = 0;
        for (; i < pages.Count && !OverBudget; i++)
        {
            var page = pages[i];
            string where = PdfAText.PageName(i + 1);
            CheckGroup(page.Dictionary, where, page.Resources, true);
            CheckTriggers(page.Dictionary, where, false);
            ScanResources(page.Resources, where);
            try
            {
                CheckContent(page.Contents(), where);
                interpreter.Run(page, new Visitor(this, where, page.Resources));
                if (interpreter.IsTruncated) Add("6.1.7", where, PdfAText.TooMuchContent);
            }
            catch (PdfReadException)
            {
                Unreadable(where);
            }
            CheckAnnotations(page, i + 1, interpreter);
        }
        if (OverBudget) Unreadable(PdfAText.PageName(Math.Max(1, i)));
    }

    private void Unreadable(string where) => Add("6.1.7", where, OverBudget ? PdfAText.TooMuchContent : PdfAText.ContentUnreadable);

    private void UseDevice(string family, string where, PdfDictionary? scope)
    {
        if (!_deviceUses.Add((family, where, scope))) return;
        bool allowed = family switch
        {
            "DeviceGray" => _intentComponents != 0 || HasDefault(scope, "DefaultGray"),
            "DeviceRGB" => _intentComponents == 3 || HasDefault(scope, "DefaultRGB"),
            _ => _intentComponents == 4 || HasDefault(scope, "DefaultCMYK"),
        };
        if (!allowed) Add(C("6.2.3.3", "6.2.4.3"), where, PdfAText.DeviceColor(family));
    }

    // A default space counts in the resource dictionary of the content that uses the device space (ISO 32000-1 8.6.5.6).
    private bool HasDefault(PdfDictionary? scope, string name) => _doc.Dict(scope, "ColorSpace")?.ContainsKey(name) == true;

    // A form is parsed once but run at every paint, so each paint costs its operations, and the bytes inflated again when the interpreter has no room
    // to keep it. A form that could not be read may be inflated again at every paint, so it costs what that takes at most.
    private void Charge(PdfStream form, string where)
    {
        long cost = MaxStreamBytes;
        if (_formCosts.TryGetValue(form, out var known))
        {
            if (known.Operations > MaxFormOperations) Add("6.1.7", where, PdfAText.TooMuchContent);
            cost = known.Operations + (IsKept(form, known.Operations) ? 0 : known.Size);
        }
        _work += cost + 1;
        if (OverBudget) throw PdfReadException.Damaged(PdfAText.TooMuchContent);
    }

    // Follows the interpreter's cache, which takes forms in the order they are first painted and keeps a form it skipped as empty.
    private bool IsKept(PdfStream form, int operations)
    {
        if (_cachedForms.Contains(form)) return true;
        int held = operations > MaxFormOperations ? 0 : operations;
        if (_cachedForms.Count >= MaxCachedForms || _cachedOperations + held > MaxCachedOperations) return false;
        _cachedForms.Add(form);
        _cachedOperations += held;
        return true;
    }

    private IReadOnlyList<ContentOperation> CheckContent(byte[] data, string where)
    {
        int depth = 0, deepest = 0;
        _work += data.Length;
        if (HasBadHexString(data, true)) Add("6.1.6", where, PdfAText.HexString);
        var operations = ContentParser.Parse(data, MaxOperations);
        foreach (var op in operations)
        {
            foreach (var operand in op.Operands) CheckOperand(operand, where);
            switch (op.Operator)
            {
                case "q":
                    deepest = Math.Max(deepest, ++depth);
                    break;
                case "Q":
                    depth = Math.Max(0, depth - 1);
                    break;
                case "ri":
                    if (op.Operands.Count > 0 && op.Operands[0] is PdfName intent) CheckIntent(intent.Value, where);
                    break;
            }
            if (!Operators.Contains(op.Operator)) Add(C("6.2.10", "6.2.2"), where, PdfAText.UnknownOperator(op.Operator));
        }
        if (deepest > 28) Add(C("6.1.12", "6.1.13"), where, PdfAText.GraphicsNesting);
        return operations;
    }

    private void CheckOperand(PdfObject operand, string where)
    {
        CheckLimits(operand, where);
        IEnumerable<PdfObject> children = operand switch { PdfArray array => array.Items, PdfDictionary dictionary => dictionary.Entries.Select(e => e.Value), _ => [] };
        foreach (var child in children) CheckOperand(child, where);
    }

    private void CheckIntent(string? intent, string where)
    {
        if (intent is not null && !RenderingIntents.Contains(intent)) Add(ClauseIntent, where, PdfAText.RenderingIntent(intent));
    }

    private void CheckGroup(PdfDictionary owner, string where, PdfDictionary? scope, bool countDevice)
    {
        if (_doc.Dict(owner, "Group") is not { } group) return;
        if (IsPart1 && _doc.Name(group, "S") == "Transparency") Add(ClauseTransparency, where, PdfAText.TransparencyGroup);
        if (group.ContainsKey("CS")) CheckColorSpace(group["CS"], where, scope, countDevice);
    }

    private void ScanResources(PdfDictionary? resources, string where)
    {
        if (resources is null || _scanDepth >= MaxScanDepth || !_resourcesSeen.Add(resources)) return;
        _scanDepth++;
        try
        {
            ScanCategories(resources, where);
        }
        finally
        {
            _scanDepth--;
        }
    }

    private void ScanCategories(PdfDictionary resources, string where)
    {
        foreach (var state in Entries(resources, "ExtGState").OfType<PdfDictionary>()) CheckExtGState(state, where);
        foreach (var space in Entries(resources, "ColorSpace")) CheckColorSpace(space, where, resources, false);
        foreach (var shading in Entries(resources, "Shading")) CheckShading(shading, where, resources, false);
        foreach (var pattern in Entries(resources, "Pattern"))
        {
            if (pattern is PdfStream tiling) CheckFormStream(tiling, where);
            else if (pattern is PdfDictionary dictionary)
            {
                foreach (var state in new[] { _doc.Dict(dictionary, "ExtGState") }.OfType<PdfDictionary>()) CheckExtGState(state, where);
                CheckShading(dictionary["Shading"], where, resources, false);
            }
        }
        foreach (var xobject in Entries(resources, "XObject").OfType<PdfStream>())
        {
            switch (_doc.Name(xobject.Dictionary, "Subtype"))
            {
                case "Image":
                    CheckImage(xobject, where);
                    break;
                case "Form":
                    CheckFormStream(xobject, where);
                    break;
                case "PS":
                    Add(ClausePostScript, where, PdfAText.PostScriptObject);
                    break;
            }
        }
        foreach (var font in Entries(resources, "Font").OfType<PdfDictionary>())
        {
            ScanResources(_doc.Dict(font, "Resources"), where);
            foreach (var glyphProcedure in Entries(font, "CharProcs").OfType<PdfStream>()) CheckFormStream(glyphProcedure, where);
        }
    }

    private IEnumerable<PdfObject> Entries(PdfDictionary owner, string key) =>
        _doc.Dict(owner, key) is { } category
            ? category.Entries.Take(100_000).Select(e => _doc.Resolve(e.Value)).OfType<PdfObject>()
            : [];

    private void CheckExtGState(PdfDictionary state, string where)
    {
        if (_doc.Dict(state, "SMask") is { } mask && _doc.Stream(mask, "G") is { } group) ScanText(group, _doc.Dict(group.Dictionary, "Resources"), where);
        if (state.ContainsKey("TR")) Add(ClauseState, where, PdfAText.TransferFunction);
        if (state.ContainsKey("TR2") && _doc.Name(state, "TR2") != "Default") Add(ClauseState, where, PdfAText.TransferFunction);
        if (state.ContainsKey("HTP")) Add(ClauseState, where, PdfAText.Halftone);
        CheckIntent(_doc.Name(state, "RI"), where);
        var blend = _doc.Resolve(state["BM"]);
        if (!IsPart1)
        {
            var modes = blend is PdfArray list ? list.Items.Take(16).Select(i => (_doc.Resolve(i) as PdfName)?.Value) : [(blend as PdfName)?.Value];
            foreach (string? name in modes)
            {
                if (name is not null && !BlendModes.Contains(name)) Add(ClauseTransparency, where, PdfAText.UnknownBlendMode(name));
            }
            return;
        }
        string? mode = blend is PdfArray { Items.Count: > 0 } first ? (_doc.Resolve(first.Items[0]) as PdfName)?.Value : (blend as PdfName)?.Value;
        if (mode is not (null or "Normal" or "Compatible")) Add(ClauseTransparency, where, PdfAText.BlendMode(mode));
        if (_doc.Number(state, "CA") is < 1 || _doc.Number(state, "ca") is < 1) Add(ClauseTransparency, where, PdfAText.Opacity);
        if (_doc.Resolve(state["SMask"]) is not (null or PdfName { Value: "None" })) Add(ClauseTransparency, where, PdfAText.SoftMask);
    }

    private void CheckFormStream(PdfStream form, string where)
    {
        if (!_streamsSeen.Add(form)) return;
        var d = form.Dictionary;
        if (d.ContainsKey("Ref")) Add(ClauseReference, where, PdfAText.ReferenceXObject);
        if (_doc.Name(d, "Subtype2") == "PS" || d.ContainsKey("PS")) Add(ClausePostScript, where, PdfAText.PostScriptObject);
        if (d.ContainsKey("OPI")) Add(ClauseForms, where, PdfAText.Opi);
        var resources = _doc.Dict(d, "Resources");
        CheckGroup(d, where, resources, false);
        ScanResources(resources, where);
        if (OverBudget) return;
        try
        {
            byte[] data = _doc.Data(form, MaxStreamBytes);
            var operations = CheckContent(data, where);
            _formCosts[form] = new FormCost(operations.Count, data.Length, operations.Any(o => o.Operator is "Do" or "scn" or "SCN"));
        }
        catch (PdfReadException)
        {
            Unreadable(where);
        }
    }

    private void CheckImage(PdfStream image, string where)
    {
        if (!_streamsSeen.Add(image)) return;
        var d = image.Dictionary;
        if (_doc.Bool(d, "Interpolate") == true) Add(ClauseImages, where, PdfAText.Interpolate);
        if (d.ContainsKey("OPI")) Add(ClauseImages, where, PdfAText.Opi);
        if (d.ContainsKey("Alternates")) Add(ClauseImages, where, PdfAText.Alternates);
        CheckIntent(_doc.Name(d, "Intent"), where);
        if (_doc.Bool(d, "ImageMask") != true) CheckColorSpace(d["ColorSpace"], where, null, false);
        if (IsPart1)
        {
            if (_doc.Resolve(d["SMask"]) is not null || _doc.Integer(d, "SMaskInData") is > 0) Add(ClauseTransparency, where, PdfAText.ImageTransparency);
            if (FilterNames(d).Contains("JPXDecode")) Add(ClauseImages, where, PdfAText.Jpx);
        }
    }

    private void CheckInlineImage(PdfDictionary image, string where, PdfDictionary? scope)
    {
        if (_doc.Bool(image, "Interpolate") == true) Add(ClauseImages, where, PdfAText.Interpolate);
        CheckFilters(image, where, true);
        if (_doc.Bool(image, "ImageMask") != true && image["ColorSpace"] is { } space) CheckColorSpace(space, where, scope, true);
    }

    private void CheckShading(PdfObject? shading, string where, PdfDictionary? scope, bool countDevice)
    {
        var d = _doc.Resolve(shading) switch { PdfStream s => s.Dictionary, PdfDictionary dictionary => dictionary, _ => null };
        if (d is not null) CheckColorSpace(d["ColorSpace"], where, scope, countDevice);
    }

    /// <summary>
    /// Device spaces count as used, in the resources <paramref name="scope"/>, only where <paramref name="countDevice"/> is set; the alternate
    /// of a Separation is not a use, and a space merely listed in a resource dictionary is not one until something paints with it.
    /// </summary>
    private void CheckColorSpace(PdfObject? space, string where, PdfDictionary? scope, bool countDevice, int depth = 0)
    {
        space = _doc.Resolve(space);
        if (depth > 8 || space is null) return;
        if (space is PdfName name)
        {
            if (countDevice && name.Value is "DeviceGray" or "DeviceRGB" or "DeviceCMYK" or "G" or "RGB" or "CMYK")
                UseDevice(name.Value switch { "G" => "DeviceGray", "RGB" => "DeviceRGB", "CMYK" => "DeviceCMYK", var n => n }, where, scope);
            return;
        }
        if (space is not PdfArray { Items.Count: > 0 } array || _doc.Resolve(array.Items[0]) is not PdfName family) return;
        PdfObject? Item(int i) => i < array.Items.Count ? array.Items[i] : null;
        switch (family.Value)
        {
            case "ICCBased":
                if (_doc.Resolve(Item(1)) is PdfStream profile) CheckProfile(profile, where);
                break;
            case "Indexed" or "I" or "Pattern":
                CheckColorSpace(Item(1), where, scope, countDevice, depth + 1);
                break;
            case "Separation":
                CheckSeparation(array, where);
                CheckColorSpace(Item(2), where, scope, false, depth + 1);
                break;
            case "DeviceN":
                if (_doc.Resolve(Item(1)) is PdfArray colorants && colorants.Items.Count > (IsPart1 ? 8 : 32))
                    Add(C("6.1.12", "6.1.13"), where, PdfAText.TooManyColorants(IsPart1 ? 8 : 32));
                CheckColorSpace(Item(2), where, scope, false, depth + 1);
                break;
            case "DeviceGray" or "DeviceRGB" or "DeviceCMYK":
                CheckColorSpace(array.Items[0], where, scope, countDevice, depth + 1);
                break;
        }
    }

    // 6.2.3.4 / 6.2.4.4: every Separation of one colorant name has the same alternate space and tint transform.
    private void CheckSeparation(PdfArray array, string where)
    {
        if (array.Items.Count < 4 || _doc.Resolve(array.Items[1]) is not PdfName colorant) return;
        string signature = $"{array.Items[2]}|{array.Items[3]}";
        if (!_separations.TryAdd(colorant.Value, signature) && _separations[colorant.Value] != signature)
            Add(C("6.2.3.4", "6.2.4.4"), where, PdfAText.SeparationDiffers(colorant.Value));
    }

    private void CheckProfile(PdfStream profile, string where)
    {
        if (!_streamsSeen.Add(profile) || OverBudget) return;
        string clause = C("6.2.3.2", "6.2.4.2");
        long? n = _doc.Integer(profile.Dictionary, "N");
        if (n is not (1 or 3 or 4))
        {
            Add(clause, where, PdfAText.ProfileComponents);
            return;
        }
        byte[] data;
        try
        {
            data = _doc.Data(profile, 32L << 20);
            _work += data.Length;
        }
        catch (PdfReadException)
        {
            Add(clause, where, PdfAText.ProfileUnreadable);
            return;
        }
        if (IccProblem(data, (int)n, IsPart1 ? 2 : 4) is { } problem) Add(clause, where, problem);
    }

    /// <summary>
    /// What is wrong with an ICC profile for PDF/A, or null: size, signature, class, colour space against /N, major version.
    /// An output intent profile must be of class prtr or mntr and a plain RGB, gray or CMYK one; an ICCBased space may also be scnr or spac, or Lab with /N 3.
    /// </summary>
    internal static string? IccProblem(byte[] profile, int components, int highestVersion, bool outputIntent = false)
    {
        if (profile.Length < 128 || !profile.AsSpan(36, 4).SequenceEqual("acsp"u8)) return PdfAText.ProfileUnreadable;
        string kind = System.Text.Encoding.ASCII.GetString(profile, 12, 4);
        string space = System.Text.Encoding.ASCII.GetString(profile, 16, 4);
        if (kind is not ("mntr" or "prtr") && (outputIntent || kind is not ("scnr" or "spac"))) return PdfAText.ProfileClass(kind);
        if (space != (components switch { 1 => "GRAY", 3 => "RGB ", _ => "CMYK" }) && !(components == 3 && !outputIntent && space == "Lab ")) return PdfAText.ProfileSpace;
        if (profile[8] > highestVersion) return PdfAText.ProfileVersion(profile[8]);
        return null;
    }

    // A shading pattern is painted in the space of its shading, and an Indexed space paints through its base.
    private void UseColor(PdfColor color, string where, PdfDictionary? scope)
    {
        if (color.Pattern is PdfDictionary pattern) CheckShading(pattern["Shading"], where, scope, true);
        var used = color.Space.Family == "Pattern" ? color.Space.Base : color.Space;
        if (used?.Family == "Indexed") CheckColorSpace(used.Definition, where, scope, true);
        else if (used?.Family is "DeviceGray" or "DeviceRGB" or "DeviceCMYK") UseDevice(used.Family, where, scope);
    }

    private void NoteGlyph(ContentContext context, in GlyphInfo glyph, string where, PdfDictionary? scope)
    {
        int mode = context.State.RenderMode % 4;
        if (mode is 0 or 2) UseColor(context.State.FillColor, where, scope);
        if (mode is 1 or 2) UseColor(context.State.StrokeColor, where, scope);
        var font = glyph.Font;
        if (context.State.RenderMode != 3) _renderedFonts.Add(font.Dictionary);
        int key = font.IsComposite ? glyph.Character.Cid : glyph.Code;
        if ((uint)key > 0xFFFF) return;
        var used = UsesOf(font.Dictionary, where, scope);
        if (used.Count >= MaxFontCodes || !used.Add(key) || font.IsType3) return;
        double? program = font.IsComposite ? font.ProgramCidWidth(key) : font.ProgramWidth(key);
        if (program is { } own && Math.Abs(own - glyph.Character.Width) > 1)
            Add(C("6.3.6", "6.2.11.5"), PdfAText.FontName(font.BaseFont), PdfAText.WidthDiffers(key, glyph.Character.Width, own));
    }

    private sealed class Visitor(PdfAChecker checker, string where, PdfDictionary? resources) : ContentVisitor
    {
        // The resources whose Default spaces apply: those of the innermost form that has any, else the page's.
        private readonly Stack<PdfDictionary?> _scopes = new([resources]);

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => checker.NoteGlyph(context, glyph, where, _scopes.Peek());

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill) checker.UseColor(context.State.FillColor, where, _scopes.Peek());
            if (path.Stroke) checker.UseColor(context.State.StrokeColor, where, _scopes.Peek());
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (image.Stream is { } stream)
            {
                checker.CheckImage(stream, where);
                if (!image.IsMask) checker.CheckColorSpace(image.Dictionary["ColorSpace"], where, _scopes.Peek(), true);
            }
            else
            {
                checker.CheckInlineImage(image.Dictionary, where, _scopes.Peek());
            }
            if (image.IsMask) checker.UseColor(context.State.FillColor, where, _scopes.Peek());
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading) => checker.CheckShading(shading.Shading, where, _scopes.Peek(), true);

        public override void BeginForm(ContentContext context, FormInfo form)
        {
            checker.CheckFormStream(form.Stream, where);
            checker.Charge(form.Stream, where);
            if (context.Forms.Count >= MaxFormDepth && checker._formCosts.TryGetValue(form.Stream, out var cost) && cost.Nests)
                checker.Add("6.1.7", where, PdfAText.TooMuchContent);
            _scopes.Push(checker._doc.Dict(form.Stream.Dictionary, "Resources") ?? _scopes.Peek());
            checker.CheckGroup(form.Stream.Dictionary, where, _scopes.Peek(), true);
        }

        public override void EndForm(ContentContext context, FormInfo form) => _scopes.Pop();
    }
}
