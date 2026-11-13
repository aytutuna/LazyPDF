using System.Globalization;

namespace LazyPDF.Core.Office;

/// <summary>Reads xl/styles.xml: number format codes, fonts, fills, borders and the cell formats that tie them together.</summary>
internal static class XlsxStylesReader
{
    private const string M = XlsxReader.M;

    private static readonly int[] Palette =
    [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ];

    private static readonly string[] ThemeNames = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"];

    private static readonly Dictionary<string, double> DigitRatio = new()
    {
        ["calibri"] = 0.507, ["carlito"] = 0.507, ["arial"] = 0.556, ["helvetica"] = 0.556, ["liberation sans"] = 0.556,
        ["times new roman"] = 0.5, ["liberation serif"] = 0.5, ["courier new"] = 0.6, ["liberation mono"] = 0.6,
        ["verdana"] = 0.636, ["tahoma"] = 0.546, ["cambria"] = 0.55, ["caladea"] = 0.55,
    };

    public static XlsxStyles Read(XmlElement? root, DocxTheme theme, XlsxLimits limits)
    {
        var styles = new XlsxStyles();
        if (root is { Uri: M, Name: "styleSheet" })
        {
            foreach (var n in root.Child(M, "numFmts")?.Elements(M, "numFmt") ?? [])
            {
                if (XlsxParse.Int(n.Attribute("numFmtId")) is not { } id || n.Attribute("formatCode") is not { } code) continue;
                if (styles.Codes.Count >= limits.MaxNumberFormats) throw TooMany("number formats");
                styles.Codes[id] = code;
            }
            foreach (var f in Items(root, "fonts", "font", limits)) styles.Fonts.Add(ReadFont(f, theme));
            foreach (var f in Items(root, "fills", "fill", limits)) styles.Fills.Add(ReadFill(f, theme));
            foreach (var b in Items(root, "borders", "border", limits)) styles.Borders.Add(ReadBorder(b, theme));
            foreach (var x in Items(root, "cellXfs", "xf", limits)) styles.Xfs.Add(ReadXf(x));
        }
        if (styles.Fonts.Count == 0) styles.Fonts.Add(new XlsxFont("Calibri", 11, false, false, false, false, null));
        if (styles.Fills.Count == 0) styles.Fills.Add(new XlsxFill(null, false));
        if (styles.Borders.Count == 0) styles.Borders.Add(new XlsxBorder(null, null, null, null));
        if (styles.Xfs.Count == 0) styles.Xfs.Add(new XlsxXf(0, 0, 0, 0, XlsxHorizontal.General, XlsxVertical.Bottom, false, 0, false));
        styles.MaxDigitWidth = DigitWidth(styles.Fonts[0]);
        return styles;
    }

    private static PdfReadException TooMany(string what) => new(PdfReadProblem.Unsupported, $"The workbook has too many {what}.");

    private static IEnumerable<XmlElement> Items(XmlElement root, string list, string item, XlsxLimits limits)
    {
        var all = root.Child(M, list)?.Elements(M, item).ToList() ?? [];
        if (all.Count > limits.MaxStyles) throw TooMany("cell formats");
        return all;
    }

    private static int DigitWidth(XlsxFont font)
    {
        double ratio = DigitRatio.GetValueOrDefault(Lower(font.Name), 0.507);
        return Math.Max(1, (int)Math.Floor(font.Size * 96 / 72 * ratio + 0.5));
    }

    private static string Lower(string s) => new([.. s.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c)]);

    private static XlsxFont ReadFont(XmlElement f, DocxTheme theme)
    {
        bool Flag(string name) => f.Child(M, name) is { } e && XlsxParse.Flag(e.Attribute("val"), true);
        string? underline = f.Child(M, "u") is { } u ? u.Attribute("val") ?? "single" : null;
        double size = XlsxParse.Double(f.Child(M, "sz")?.Attribute("val")) is { } s && s > 0 && s <= 409 ? s : 11;
        string name = f.Child(M, "name")?.Attribute("val") is { Length: > 0 } n ? n : "Calibri";
        return new XlsxFont(name, size, Flag("b"), Flag("i"), underline is not null && underline != "none", Flag("strike"), ReadColor(f.Child(M, "color"), theme));
    }

    /// <summary>The font of a rich text run: what the run states, else the font of the cell format.</summary>
    public static XlsxFont RunFont(XmlElement? props, XlsxFont baseFont, DocxTheme theme)
    {
        if (props is null) return baseFont;
        bool Flag(string name) => props.Child(M, name) is { } e && XlsxParse.Flag(e.Attribute("val"), true);
        string? underline = props.Child(M, "u") is { } u ? u.Attribute("val") ?? "single" : null;
        string name = props.Child(M, "rFont")?.Attribute("val") is { Length: > 0 } n ? n : baseFont.Name;
        double size = XlsxParse.Double(props.Child(M, "sz")?.Attribute("val")) is { } s && s > 0 && s <= 409 ? s : baseFont.Size;
        int? color = props.Child(M, "color") is { } c ? ReadColor(c, theme) : baseFont.Color;
        return new XlsxFont(name, size, Flag("b"), Flag("i"), underline is not null && underline != "none", Flag("strike"), color);
    }

    private static XlsxFill ReadFill(XmlElement f, DocxTheme theme)
    {
        if (f.Child(M, "patternFill") is not { } pattern) return new XlsxFill(null, f.Child(M, "gradientFill") is not null);
        string type = pattern.Attribute("patternType") ?? "none";
        if (type == "none") return new XlsxFill(null, false);
        if (type != "solid") return new XlsxFill(null, true);
        return new XlsxFill(ReadColor(pattern.Child(M, "fgColor"), theme), false);
    }

    private static XlsxBorder ReadBorder(XmlElement b, DocxTheme theme)
    {
        XlsxBorderEdge? Edge(string name, string alternative)
        {
            var e = b.Child(M, name) ?? b.Child(M, alternative);
            string? style = e?.Attribute("style");
            return style is null or "none" ? null : new XlsxBorderEdge(style, ReadColor(e!.Child(M, "color"), theme));
        }
        return new XlsxBorder(Edge("left", "start"), Edge("right", "end"), Edge("top", "top"), Edge("bottom", "bottom"));
    }

    private static XlsxXf ReadXf(XmlElement x)
    {
        var a = x.Child(M, "alignment");
        var horizontal = a?.Attribute("horizontal") switch
        {
            "left" => XlsxHorizontal.Left, "center" => XlsxHorizontal.Center, "right" => XlsxHorizontal.Right, "fill" => XlsxHorizontal.Fill,
            "justify" => XlsxHorizontal.Justify, "centerContinuous" => XlsxHorizontal.CenterContinuous, "distributed" => XlsxHorizontal.Distributed,
            _ => XlsxHorizontal.General,
        };
        var vertical = a?.Attribute("vertical") switch
        {
            "top" => XlsxVertical.Top, "center" => XlsxVertical.Center, "justify" => XlsxVertical.Justify, "distributed" => XlsxVertical.Distributed,
            _ => XlsxVertical.Bottom,
        };
        int order = XlsxParse.Int(a?.Attribute("readingOrder")) is 1 or 2 ? XlsxParse.Int(a?.Attribute("readingOrder"))!.Value : 0;
        return new XlsxXf(
            XlsxParse.Int(x.Attribute("fontId")) ?? 0, XlsxParse.Int(x.Attribute("fillId")) ?? 0, XlsxParse.Int(x.Attribute("borderId")) ?? 0,
            XlsxParse.Int(x.Attribute("numFmtId")) ?? 0, horizontal, vertical, XlsxParse.Flag(a?.Attribute("wrapText"), false),
            Math.Min(XlsxParse.Int(a?.Attribute("indent")) ?? 0, 250), (XlsxParse.Int(a?.Attribute("textRotation")) ?? 0) != 0,
            order);
    }

    private static int? ReadColor(XmlElement? e, DocxTheme theme)
    {
        if (e is null || XlsxParse.Flag(e.Attribute("auto"), false)) return null;
        int? rgb = null;
        if (XlsxParse.Hex(e.Attribute("rgb")) is { } direct) rgb = direct;
        else if (XlsxParse.Int(e.Attribute("indexed")) is { } index) rgb = index < Palette.Length ? Palette[index] : index == 65 ? 0xFFFFFF : null;
        else if (XlsxParse.Int(e.Attribute("theme")) is { } t && t < ThemeNames.Length) rgb = theme.Color(ThemeNames[t]) ?? (t == 0 ? 0xFFFFFF : t == 1 ? 0x000000 : null);
        if (rgb is null) return null;
        return XlsxParse.Double(e.Attribute("tint")) is { } tint && tint != 0 ? Tint(rgb.Value, Math.Max(-1, Math.Min(1, tint))) : rgb;
    }

    /// <summary>Lightens or darkens a color the way the file format defines tint: luminance in HLS space.</summary>
    private static int Tint(int rgb, double tint)
    {
        double r = (rgb >> 16 & 0xFF) / 255.0, g = (rgb >> 8 & 0xFF) / 255.0, b = (rgb & 0xFF) / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double l = (max + min) / 2, h = 0, s = 0;
        if (max != min)
        {
            double d = max - min;
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            if (max == r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
            else if (max == g) h = ((b - r) / d + 2) / 6;
            else h = ((r - g) / d + 4) / 6;
        }
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;
        if (s == 0) r = g = b = l;
        else
        {
            double q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
            r = Hue(p, q, h + 1.0 / 3);
            g = Hue(p, q, h);
            b = Hue(p, q, h - 1.0 / 3);
        }
        int Byte(double v) => (int)Math.Floor(Math.Max(0, Math.Min(1, v)) * 255 + 0.5);
        return Byte(r) << 16 | Byte(g) << 8 | Byte(b);
    }

    private static double Hue(double p, double q, double t)
    {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1.0 / 6) return p + (q - p) * 6 * t;
        if (t < 0.5) return q;
        if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
        return p;
    }
}

/// <summary>Reads the numbers and flags that attributes carry, the same way in both engines: no signs, spaces or locale.</summary>
internal static class XlsxParse
{
    public static int? Int(string? text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > 9 || text.Any(c => c is < '0' or > '9')) return null;
        return int.Parse(text, CultureInfo.InvariantCulture);
    }

    public static double? Double(string? text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > 40 || text.Any(c => !(c is >= '0' and <= '9' or '+' or '-' or '.' or 'e' or 'E'))) return null;
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) && double.IsFinite(v) ? v : null;
    }

    /// <summary>Removes the spaces, tabs and line ends XML allows around a value, and nothing else, so both engines trim alike.</summary>
    public static string Trim(string text) => text.Trim(' ', '\t', '\n', '\r');

    public static bool Flag(string? text, bool whenMissing) => text switch
    {
        null => whenMissing,
        "1" or "true" => true,
        _ => false,
    };

    /// <summary>The 0xRRGGBB of an AARRGGBB or RRGGBB attribute.</summary>
    public static int? Hex(string? text)
    {
        if (text is not { Length: 6 or 8 } || text.Any(c => !(c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F'))) return null;
        return int.Parse(text[^6..], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
    }
}
