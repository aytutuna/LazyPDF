namespace LazyPDF.Core;

// Pages as drawn: content stream operators, colour, transparency, images, forms and fonts in use.
// The interpreter walks each page and enters forms and patterns; resource dictionaries are scanned
// as well, so a graphics state or image that is defined but not yet painted is held to the same rules.
internal sealed partial class PdfAChecker
{
    private static readonly HashSet<string> Operators =
    [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI", "EMC", "ET", "EX",
        "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
        "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w",
        "W", "W*", "y", "'", "\"",
    ];

    private const int MaxScanDepth = 32;
    private const int MaxFontCodes = 70_000;

    private static readonly string[] RenderingIntents = ["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"];

    private readonly HashSet<PdfDictionary> _resourcesSeen = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _streamsSeen = new(ReferenceEqualityComparer.Instance);
    private readonly List<(string Family, string Where)> _deviceUses = [];
    private readonly HashSet<string> _defaults = [];
    private readonly Dictionary<string, string> _separations = [];
    private int _scanDepth;

    /// <summary>Colour components of the output intent's profile; 0 when the file has none.</summary>
    private int _intentComponents;

    private string ClauseImages => C("6.2.4", "6.2.8");
    private string ClauseForms => C("6.2.5", "6.2.9");
    private string ClauseTransparency => C("6.4", "6.2.10");
    private string ClauseState => C("6.2.8", "6.2.5");
    private string ClauseIntent => C("6.2.9", "6.2.6");

    private void CheckPages()
    {
        var interpreter = new ContentInterpreter(_doc);
        var pages = _doc.Pages;
        for (int i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            string where = PdfAText.PageName(i + 1);
            CheckGroup(page.Dictionary, where);
            CheckTriggers(page.Dictionary, where, false);
            ScanResources(page.Resources, where);
            CheckContent(page.Contents(), where);
            try
            {
                interpreter.Run(page, new Visitor(this, where));
            }
            catch (PdfReadException)
            {
                Add("6.1.7", where, PdfAText.ContentUnreadable);
            }
            CheckAnnotations(page, i + 1, interpreter);
        }
        foreach (var (family, where) in _deviceUses)
        {
            bool allowed = family switch
            {
                "DeviceGray" => _intentComponents != 0 || _defaults.Contains("DefaultGray"),
                "DeviceRGB" => _intentComponents == 3 || _defaults.Contains("DefaultRGB"),
                _ => _intentComponents == 4 || _defaults.Contains("DefaultCMYK"),
            };
            if (!allowed) Add(C("6.2.3.3", "6.2.4.3"), where, PdfAText.DeviceColor(family));
        }
    }

    private void CheckContent(byte[] data, string where)
    {
        int depth = 0, deepest = 0;
        foreach (var op in ContentParser.Parse(data))
        {
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
    }

    private void CheckIntent(string? intent, string where)
    {
        if (intent is not null && !RenderingIntents.Contains(intent)) Add(ClauseIntent, where, PdfAText.RenderingIntent(intent));
    }

    private void CheckGroup(PdfDictionary owner, string where)
    {
        if (_doc.Dict(owner, "Group") is not { } group) return;
        if (IsPart1 && _doc.Name(group, "S") == "Transparency") Add(ClauseTransparency, where, PdfAText.TransparencyGroup);
        if (group.ContainsKey("CS")) CheckColorSpace(group["CS"], where, true);
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
        foreach (string name in (ReadOnlySpan<string>)["DefaultGray", "DefaultRGB", "DefaultCMYK"])
        {
            if (_doc.Dict(resources, "ColorSpace")?.ContainsKey(name) == true) _defaults.Add(name);
        }
        foreach (var space in Entries(resources, "ColorSpace")) CheckColorSpace(space, where, true);
        foreach (var shading in Entries(resources, "Shading")) CheckShading(shading, where);
        foreach (var pattern in Entries(resources, "Pattern"))
        {
            if (pattern is PdfStream tiling) CheckFormStream(tiling, where);
            else if (pattern is PdfDictionary dictionary)
            {
                foreach (var state in new[] { _doc.Dict(dictionary, "ExtGState") }.OfType<PdfDictionary>()) CheckExtGState(state, where);
                CheckShading(dictionary["Shading"], where);
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
                    Add(C("6.2.6", "6.2.9"), where, PdfAText.PostScriptObject);
                    break;
            }
        }
        foreach (var font in Entries(resources, "Font").OfType<PdfDictionary>())
        {
            _fonts.Add(font);
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
        if (state.ContainsKey("TR")) Add(ClauseState, where, PdfAText.TransferFunction);
        if (state.ContainsKey("TR2") && _doc.Name(state, "TR2") != "Default") Add(ClauseState, where, PdfAText.TransferFunction);
        if (state.ContainsKey("HTP")) Add(ClauseState, where, PdfAText.Halftone);
        CheckIntent(_doc.Name(state, "RI"), where);
        if (!IsPart1) return;
        var blend = _doc.Resolve(state["BM"]);
        string? mode = blend is PdfArray { Items.Count: > 0 } list ? (_doc.Resolve(list.Items[0]) as PdfName)?.Value : (blend as PdfName)?.Value;
        if (mode is not (null or "Normal" or "Compatible")) Add(ClauseTransparency, where, PdfAText.BlendMode(mode));
        if (_doc.Number(state, "CA") is < 1 || _doc.Number(state, "ca") is < 1) Add(ClauseTransparency, where, PdfAText.Opacity);
        if (_doc.Resolve(state["SMask"]) is not (null or PdfName { Value: "None" })) Add(ClauseTransparency, where, PdfAText.SoftMask);
    }

    private void CheckFormStream(PdfStream form, string where)
    {
        if (!_streamsSeen.Add(form)) return;
        var d = form.Dictionary;
        if (d.ContainsKey("Ref")) Add(ClauseForms, where, PdfAText.ReferenceXObject);
        if (_doc.Name(d, "Subtype2") == "PS" || d.ContainsKey("PS")) Add(ClauseForms, where, PdfAText.PostScriptObject);
        if (d.ContainsKey("OPI")) Add(ClauseForms, where, PdfAText.Opi);
        CheckGroup(d, where);
        ScanResources(_doc.Dict(d, "Resources"), where);
        try
        {
            CheckContent(_doc.Data(form, 64L << 20), where);
        }
        catch (PdfReadException)
        {
            Add("6.1.7", where, PdfAText.ContentUnreadable);
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
        if (_doc.Bool(d, "ImageMask") != true) CheckColorSpace(d["ColorSpace"], where, true);
        if (IsPart1)
        {
            if (_doc.Resolve(d["SMask"]) is not null || _doc.Integer(d, "SMaskInData") is > 0) Add(ClauseTransparency, where, PdfAText.ImageTransparency);
            if (FilterNames(d).Contains("JPXDecode")) Add(ClauseImages, where, PdfAText.Jpx);
        }
    }

    private void CheckInlineImage(PdfDictionary image, string where)
    {
        if (_doc.Bool(image, "Interpolate") == true) Add(ClauseImages, where, PdfAText.Interpolate);
        CheckFilters(FilterNames(image), where);
        if (_doc.Bool(image, "ImageMask") != true && image["ColorSpace"] is { } space) CheckColorSpace(space, where, true);
    }

    private void CheckShading(PdfObject? shading, string where)
    {
        var d = _doc.Resolve(shading) switch { PdfStream s => s.Dictionary, PdfDictionary dictionary => dictionary, _ => null };
        if (d is not null) CheckColorSpace(d["ColorSpace"], where, true);
    }

    /// <summary>Device spaces count as used only where <paramref name="countDevice"/> is set; the alternate of a Separation is not a use.</summary>
    private void CheckColorSpace(PdfObject? space, string where, bool countDevice, int depth = 0)
    {
        space = _doc.Resolve(space);
        if (depth > 8 || space is null) return;
        if (space is PdfName name)
        {
            if (countDevice && name.Value is "DeviceGray" or "DeviceRGB" or "DeviceCMYK" or "G" or "RGB" or "CMYK")
                _deviceUses.Add((name.Value switch { "G" => "DeviceGray", "RGB" => "DeviceRGB", "CMYK" => "DeviceCMYK", var n => n }, where));
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
                CheckColorSpace(Item(1), where, countDevice, depth + 1);
                break;
            case "Separation":
                CheckSeparation(array, where);
                CheckColorSpace(Item(2), where, false, depth + 1);
                break;
            case "DeviceN":
                if (_doc.Resolve(Item(1)) is PdfArray { Items.Count: > 32 }) Add(C("6.1.12", "6.1.13"), where, PdfAText.TooManyColorants);
                CheckColorSpace(Item(2), where, false, depth + 1);
                break;
            case "DeviceGray" or "DeviceRGB" or "DeviceCMYK":
                CheckColorSpace(array.Items[0], where, countDevice, depth + 1);
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
        if (!_streamsSeen.Add(profile)) return;
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
        }
        catch (PdfReadException)
        {
            Add(clause, where, PdfAText.ProfileUnreadable);
            return;
        }
        if (IccProblem(data, (int)n, IsPart1 ? 2 : 4) is { } problem) Add(clause, where, problem);
    }

    /// <summary>What is wrong with an ICC profile for PDF/A, or null: size, signature, class, colour space against /N, major version.</summary>
    internal static string? IccProblem(byte[] profile, int components, int highestVersion)
    {
        if (profile.Length < 128 || !profile.AsSpan(36, 4).SequenceEqual("acsp"u8)) return PdfAText.ProfileUnreadable;
        string kind = System.Text.Encoding.ASCII.GetString(profile, 12, 4);
        string space = System.Text.Encoding.ASCII.GetString(profile, 16, 4);
        if (kind is not ("scnr" or "mntr" or "prtr" or "spac")) return PdfAText.ProfileClass(kind);
        if (space != (components switch { 1 => "GRAY", 3 => "RGB ", _ => "CMYK" })) return PdfAText.ProfileSpace;
        if (profile[8] > highestVersion) return PdfAText.ProfileVersion(profile[8]);
        return null;
    }

    private void UseColor(ColorSpaceInfo space, string where)
    {
        var used = space.Family == "Pattern" ? space.Base : space;
        if (used?.Family is "DeviceGray" or "DeviceRGB" or "DeviceCMYK") _deviceUses.Add((used.Family, where));
    }

    private void NoteGlyph(ContentContext context, in GlyphInfo glyph, string where)
    {
        int mode = context.State.RenderMode % 4;
        if (mode is 0 or 2) UseColor(context.State.FillColor.Space, where);
        if (mode is 1 or 2) UseColor(context.State.StrokeColor.Space, where);
        var font = glyph.Font;
        int key = font.IsComposite ? glyph.Character.Cid : glyph.Code;
        if ((uint)key > 0xFFFF) return;
        if (!FontUses.TryGetValue(font.Dictionary, out var used)) FontUses[font.Dictionary] = used = [];
        if (used.Count >= MaxFontCodes || !used.Add(key) || font.IsType3) return;
        double? program = font.IsComposite ? font.ProgramCidWidth(key) : font.ProgramWidth(key);
        if (program is { } own && Math.Abs(own - glyph.Character.Width) > 1)
            Add(C("6.3.6", "6.2.11.5"), PdfAText.FontName(font.BaseFont), PdfAText.WidthDiffers(key, glyph.Character.Width, own));
    }

    private sealed class Visitor(PdfAChecker checker, string where) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => checker.NoteGlyph(context, glyph, where);

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill) checker.UseColor(context.State.FillColor.Space, where);
            if (path.Stroke) checker.UseColor(context.State.StrokeColor.Space, where);
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (image.Stream is { } stream) checker.CheckImage(stream, where);
            else checker.CheckInlineImage(image.Dictionary, where);
            if (image.IsMask) checker.UseColor(context.State.FillColor.Space, where);
        }

        public override void PaintShading(ContentContext context, ShadingInfo shading) => checker.CheckShading(shading.Shading, where);

        public override void BeginForm(ContentContext context, FormInfo form) => checker.CheckFormStream(form.Stream, where);
    }
}
