namespace LazyPDF.Core.Office;

/// <summary>Run formatting as a document states it; null is "not said", so a later layer can fill it in.</summary>
internal sealed class RunProps
{
    public string? Family;
    /// <summary>Points.</summary>
    public double? Size;
    public bool? Bold, Italic, Underline, Strike, Caps, Hidden;
    /// <summary>The complex-script (Arabic, Hebrew) counterparts: font, size, bold and italic, which apply to the characters of those scripts.</summary>
    public string? CsFamily;
    public double? CsSize;
    public bool? CsBold, CsItalic;
    /// <summary>w:rtl: the run is right to left. w:cs: the run is formatted as complex script whatever its characters.</summary>
    public bool? Rtl, Complex;
    public int? Color;
    /// <summary>0xRRGGBB, or -1 for none.</summary>
    public int? Highlight;
    /// <summary>1 superscript, -1 subscript, 0 baseline.</summary>
    public int? Vertical;

    public RunProps Copy() => (RunProps)MemberwiseClone();

    public void Apply(XmlElement? rPr, DocxTheme theme)
    {
        if (rPr is null) return;
        foreach (var e in rPr.Elements())
        {
            if (e.Uri != DocxReader.W) continue;
            string? val = e.Attribute(DocxReader.W, "val");
            switch (e.Name)
            {
                case "rFonts":
                    string? themed = e.Attribute(DocxReader.W, "asciiTheme") ?? e.Attribute(DocxReader.W, "hAnsiTheme");
                    string? named = e.Attribute(DocxReader.W, "ascii") ?? e.Attribute(DocxReader.W, "hAnsi");
                    if (themed is not null && theme.Font(themed) is { } themeFont) Family = themeFont;
                    else if (!string.IsNullOrEmpty(named)) Family = named;
                    string? csThemed = e.Attribute(DocxReader.W, "cstheme");
                    string? csNamed = e.Attribute(DocxReader.W, "cs");
                    if (csThemed is not null && theme.ComplexFont(csThemed) is { } csThemeFont) CsFamily = csThemeFont;
                    else if (!string.IsNullOrEmpty(csNamed)) CsFamily = csNamed;
                    break;
                case "b": Bold = DocxReader.On(e); break;
                case "i": Italic = DocxReader.On(e); break;
                case "bCs": CsBold = DocxReader.On(e); break;
                case "iCs": CsItalic = DocxReader.On(e); break;
                case "rtl": Rtl = DocxReader.On(e); break;
                case "cs": Complex = DocxReader.On(e); break;
                case "u": Underline = val != "none"; break;
                case "strike":
                case "dstrike": Strike = DocxReader.On(e); break;
                case "caps": Caps = DocxReader.On(e); break;
                case "vanish": Hidden = DocxReader.On(e); break;
                case "color":
                    int? color = DocxReader.Hex(val) ?? (e.Attribute(DocxReader.W, "themeColor") is { } tc ? theme.Color(tc) : val == "auto" ? 0 : null);
                    if (color is not null) Color = color;
                    break;
                case "sz":
                    if (DocxReader.Number(val) is > 0 and var half) Size = half / 2;
                    break;
                case "szCs":
                    if (DocxReader.Number(val) is > 0 and var csHalf) CsSize = csHalf / 2;
                    break;
                case "highlight":
                    if (val is not null) Highlight = val == "none" ? -1 : DocxReader.HighlightColor(val) ?? Highlight;
                    break;
                case "vertAlign":
                    Vertical = val switch { "superscript" => 1, "subscript" => -1, "baseline" => 0, _ => Vertical };
                    break;
            }
        }
    }
}

/// <summary>Paragraph formatting as a document states it; lengths in points.</summary>
internal sealed class ParaProps
{
    public LayoutAlign? Align;
    public double? Left, Right, First, Before, After, Line;
    public string? LineRule;
    public bool? KeepNext, PageBreakBefore, Widow, Bidi;
    public int? NumId, Ilvl;

    public ParaProps Copy() => (ParaProps)MemberwiseClone();

    public void Apply(XmlElement? pPr)
    {
        if (pPr is null) return;
        foreach (var e in pPr.Elements())
        {
            if (e.Uri != DocxReader.W) continue;
            switch (e.Name)
            {
                case "jc":
                    Align = e.Attribute(DocxReader.W, "val") switch
                    {
                        "left" or "start" => LayoutAlign.Left,
                        "center" => LayoutAlign.Center,
                        "right" or "end" => LayoutAlign.Right,
                        "both" or "distribute" or "thaiDistribute" or "lowKashida" or "mediumKashida" or "highKashida" => LayoutAlign.Justify,
                        _ => Align,
                    };
                    break;
                case "ind":
                    Left = Length(e, "left", "start") ?? Left;
                    Right = Length(e, "right", "end") ?? Right;
                    if (Length(e, "hanging") is { } hanging) First = -hanging;
                    else if (Length(e, "firstLine") is { } first) First = first;
                    break;
                case "spacing":
                    Before = Length(e, "before") ?? Before;
                    After = Length(e, "after") ?? After;
                    if (DocxReader.Number(e.Attribute(DocxReader.W, "line")) is { } line) Line = line;
                    LineRule = e.Attribute(DocxReader.W, "lineRule") ?? LineRule;
                    break;
                case "bidi": Bidi = DocxReader.On(e); break;
                case "keepNext": KeepNext = DocxReader.On(e); break;
                case "pageBreakBefore": PageBreakBefore = DocxReader.On(e); break;
                case "widowControl": Widow = DocxReader.On(e); break;
                case "numPr":
                    if (DocxReader.Number(e.Child(DocxReader.W, "numId")?.Attribute(DocxReader.W, "val")) is { } id) NumId = (int)Math.Clamp(id, int.MinValue, int.MaxValue);
                    if (DocxReader.Number(e.Child(DocxReader.W, "ilvl")?.Attribute(DocxReader.W, "val")) is { } level) Ilvl = (int)Math.Clamp(level, int.MinValue, int.MaxValue);
                    break;
            }
        }
    }

    // Twips to points, kept inside what Word itself allows.
    private static double? Length(XmlElement e, string name, string? alias = null)
    {
        double? v = DocxReader.Number(e.Attribute(DocxReader.W, name) ?? (alias is null ? null : e.Attribute(DocxReader.W, alias)));
        return v is null ? null : Math.Clamp(v.Value / 20, -1584, 1584);
    }
}

internal sealed class DocxTheme
{
    private static readonly Dictionary<string, string> ColorNames = new()
    {
        ["text1"] = "dk1", ["dark1"] = "dk1", ["background1"] = "lt1", ["light1"] = "lt1",
        ["text2"] = "dk2", ["dark2"] = "dk2", ["background2"] = "lt2", ["light2"] = "lt2",
        ["hyperlink"] = "hlink", ["followedHyperlink"] = "folHlink",
    };

    private string? _major, _minor, _majorCs, _minorCs;
    private readonly Dictionary<string, int> _colors = [];

    public static DocxTheme Read(XmlElement? root)
    {
        var theme = new DocxTheme();
        var elements = root?.Child(DocxReader.A, "themeElements");
        var fonts = elements?.Child(DocxReader.A, "fontScheme");
        theme._major = Typeface(fonts?.Child(DocxReader.A, "majorFont"));
        theme._minor = Typeface(fonts?.Child(DocxReader.A, "minorFont"));
        theme._majorCs = Typeface(fonts?.Child(DocxReader.A, "majorFont"), "cs");
        theme._minorCs = Typeface(fonts?.Child(DocxReader.A, "minorFont"), "cs");
        foreach (var c in elements?.Child(DocxReader.A, "clrScheme")?.Elements() ?? [])
        {
            string? hex = c.Child(DocxReader.A, "srgbClr")?.Attribute("val") ?? c.Child(DocxReader.A, "sysClr")?.Attribute("lastClr");
            if (DocxReader.Hex(hex) is { } rgb) theme._colors[c.Name] = rgb;
        }
        return theme;
    }

    private static string? Typeface(XmlElement? scheme, string script = "latin")
    {
        string? name = scheme?.Child(DocxReader.A, script)?.Attribute("typeface");
        return string.IsNullOrEmpty(name) ? null : name;
    }

    /// <summary>The latin font of a theme reference such as minorHAnsi or majorAscii.</summary>
    public string? Font(string reference) =>
        reference.StartsWith("major", StringComparison.Ordinal) ? _major : reference.StartsWith("minor", StringComparison.Ordinal) ? _minor : null;

    /// <summary>The complex-script font of a theme reference such as minorBidi or majorBidi; null when the theme names none.</summary>
    public string? ComplexFont(string reference) =>
        reference.StartsWith("major", StringComparison.Ordinal) ? _majorCs : reference.StartsWith("minor", StringComparison.Ordinal) ? _minorCs : null;

    public int? Color(string name) => _colors.TryGetValue(ColorNames.GetValueOrDefault(name, name), out int rgb) ? rgb : null;
}

internal sealed record DocxStyle(string Id, string Type, string? BasedOn, XmlElement? PPr, XmlElement? RPr, XmlElement Source);

internal sealed class DocxStyles
{
    private const int MaxChain = 50;

    private readonly Dictionary<string, DocxStyle> _styles = new(StringComparer.Ordinal);
    private XmlElement? _defaultPPr, _defaultRPr;

    public string? DefaultParagraph { get; private set; }
    public string? DefaultCharacter { get; private set; }
    public string? DefaultTable { get; private set; }

    public static DocxStyles Read(XmlElement? root)
    {
        var styles = new DocxStyles();
        if (root is null) return styles;
        var defaults = root.Child(DocxReader.W, "docDefaults");
        styles._defaultPPr = defaults?.Child(DocxReader.W, "pPrDefault")?.Child(DocxReader.W, "pPr");
        styles._defaultRPr = defaults?.Child(DocxReader.W, "rPrDefault")?.Child(DocxReader.W, "rPr");
        foreach (var e in root.Elements(DocxReader.W, "style"))
        {
            string? id = e.Attribute(DocxReader.W, "styleId");
            string type = e.Attribute(DocxReader.W, "type") ?? "paragraph";
            if (id is null || styles._styles.ContainsKey(id)) continue;
            var basedOn = e.Child(DocxReader.W, "basedOn")?.Attribute(DocxReader.W, "val");
            styles._styles[id] = new DocxStyle(id, type, basedOn, e.Child(DocxReader.W, "pPr"), e.Child(DocxReader.W, "rPr"), e);
            if (e.Attribute(DocxReader.W, "default") is "1" or "true" or "on")
            {
                if (type == "paragraph") styles.DefaultParagraph ??= id;
                if (type == "character") styles.DefaultCharacter ??= id;
                if (type == "table") styles.DefaultTable ??= id;
            }
        }
        return styles;
    }

    private DocxStyle? Find(string? id, string type) =>
        id is not null && _styles.TryGetValue(id, out var s) && s.Type == type ? s : null;

    /// <summary>
    /// The document defaults, then the table style layers when the paragraph is in a table, then the paragraph style and
    /// the styles it is based on, farthest first.
    /// </summary>
    public (ParaProps Paragraph, RunProps Run) Paragraph(string? id, DocxTheme theme, IReadOnlyList<XmlElement>? tableLayers = null)
    {
        var paragraph = new ParaProps();
        var run = new RunProps();
        run.Apply(_defaultRPr, theme);
        paragraph.Apply(_defaultPPr);
        foreach (var layer in tableLayers ?? [])
        {
            paragraph.Apply(layer.Child(DocxReader.W, "pPr"));
            run.Apply(layer.Child(DocxReader.W, "rPr"), theme);
        }
        foreach (var s in Chain(Find(id, "paragraph") is null ? DefaultParagraph : id, "paragraph"))
        {
            paragraph.Apply(s.PPr);
            run.Apply(s.RPr, theme);
        }
        return (paragraph, run);
    }

    /// <summary>Puts a character style (or the default one) on top of the run properties already known.</summary>
    public void Character(string? id, RunProps run, DocxTheme theme)
    {
        foreach (var s in Chain(Find(id, "character") is null ? DefaultCharacter : id, "character")) run.Apply(s.RPr, theme);
    }

    /// <summary>The table style (or the default one) and the styles it is based on, farthest first.</summary>
    public IReadOnlyList<DocxStyle> Table(string? id) => [.. Chain(Find(id, "table") is null ? DefaultTable : id, "table")];

    private IEnumerable<DocxStyle> Chain(string? id, string type)
    {
        var chain = new List<DocxStyle>();
        for (var s = Find(id, type); s is not null && chain.Count < MaxChain && !chain.Contains(s); s = Find(s.BasedOn, type)) chain.Add(s);
        chain.Reverse();
        return chain;
    }
}
