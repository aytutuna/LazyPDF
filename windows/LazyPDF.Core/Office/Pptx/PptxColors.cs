namespace LazyPDF.Core.Office;

/// <summary>
/// Turns DrawingML color elements into 0xRRGGBB against a theme and the color map of the master: srgbClr, schemeClr, sysClr,
/// prstClr, scrgbClr and hslClr with the transforms that change lightness, saturation, hue, tint and shade, in the order
/// they are written. Alpha is ignored.
/// </summary>
internal sealed class PptxColors(DocxTheme theme, IReadOnlyDictionary<string, string> map)
{
    private const double Gamma = 2.2;

    private static readonly Dictionary<string, int> Named = new()
    {
        ["black"] = 0x000000, ["white"] = 0xFFFFFF, ["red"] = 0xFF0000, ["green"] = 0x008000, ["blue"] = 0x0000FF, ["yellow"] = 0xFFFF00,
        ["gray"] = 0x808080, ["grey"] = 0x808080, ["silver"] = 0xC0C0C0, ["maroon"] = 0x800000, ["purple"] = 0x800080, ["orange"] = 0xFFA500,
        ["lime"] = 0x00FF00, ["aqua"] = 0x00FFFF, ["cyan"] = 0x00FFFF, ["fuchsia"] = 0xFF00FF, ["magenta"] = 0xFF00FF, ["navy"] = 0x000080,
        ["teal"] = 0x008080, ["olive"] = 0x808000, ["darkBlue"] = 0x00008B, ["darkRed"] = 0x8B0000, ["darkGreen"] = 0x006400,
        ["darkGray"] = 0xA9A9A9, ["darkGrey"] = 0xA9A9A9, ["lightGray"] = 0xD3D3D3, ["lightGrey"] = 0xD3D3D3, ["dkGray"] = 0xA9A9A9, ["ltGray"] = 0xD3D3D3,
        ["pink"] = 0xFFC0CB, ["brown"] = 0xA52A2A, ["gold"] = 0xFFD700,
    };

    /// <summary>The identity mapping of a master that has no color map.</summary>
    public static readonly Dictionary<string, string> DefaultMap = new()
    {
        ["bg1"] = "lt1", ["tx1"] = "dk1", ["bg2"] = "lt2", ["tx2"] = "dk2",
        ["accent1"] = "accent1", ["accent2"] = "accent2", ["accent3"] = "accent3", ["accent4"] = "accent4", ["accent5"] = "accent5", ["accent6"] = "accent6",
        ["hlink"] = "hlink", ["folHlink"] = "folHlink",
    };

    public DocxTheme Theme => theme;

    public int? Hyperlink => Scheme("hlink");

    /// <summary>The color map written as attributes (bg1="lt1" ...) of clrMap or overrideClrMapping.</summary>
    public static Dictionary<string, string> ReadMap(XmlElement? e)
    {
        var result = new Dictionary<string, string>(DefaultMap);
        if (e is null) return result;
        foreach (var name in DefaultMap.Keys)
        {
            if (e.Attribute(name) is { } value) result[name] = value;
        }
        return result;
    }

    public PptxColors WithMap(IReadOnlyDictionary<string, string> other) => new(theme, other);

    /// <summary>The first color element inside <paramref name="parent"/> (the color of a fill, line or font reference).</summary>
    public int? First(XmlElement? parent, int? placeholder = null)
    {
        foreach (var e in parent?.Elements() ?? [])
        {
            if (e.Uri == DocxReader.A && Resolve(e, placeholder) is { } color) return color;
        }
        return null;
    }

    public int? Resolve(XmlElement e, int? placeholder)
    {
        double[]? rgb = e.Name switch
        {
            "srgbClr" => Unpack(DocxReader.Hex(e.Attribute("val"))),
            "schemeClr" => e.Attribute("val") == "phClr" ? Unpack(placeholder) : Unpack(Scheme(e.Attribute("val"))),
            "sysClr" => Unpack(DocxReader.Hex(e.Attribute("lastClr")) ?? (e.Attribute("val") == "window" ? 0xFFFFFF : e.Attribute("val") == "windowText" ? 0 : null)),
            "prstClr" => Unpack(e.Attribute("val") is { } name && Named.TryGetValue(name, out int named) ? named : null),
            "scrgbClr" => [Linear(e, "r"), Linear(e, "g"), Linear(e, "b")],
            "hslClr" => FromHsl((DocxReader.Number(e.Attribute("hue")) ?? 0) / 60000 % 360, Math.Clamp(Percent(e.Attribute("sat")), 0, 1), Math.Clamp(Percent(e.Attribute("lum")), 0, 1)),
            _ => null,
        };
        if (rgb is null) return null;
        foreach (var t in e.Elements())
        {
            if (t.Uri == DocxReader.A) Transform(ref rgb, t.Name, Percent(t.Attribute("val")), DocxReader.Number(t.Attribute("val")) ?? 0);
        }
        return Pack(rgb);
    }

    private int? Scheme(string? name)
    {
        if (name is null) return null;
        return theme.Color(map.TryGetValue(name, out string? mapped) ? mapped : name);
    }

    private static double Percent(string? value) => Math.Clamp((DocxReader.Number(value) ?? 0) / 100_000, -100, 100);

    private static double Linear(XmlElement e, string name) => Math.Clamp(Percent(e.Attribute(name)), 0, 1);

    private static double[]? Unpack(int? rgb) => rgb is { } c ? [(c >> 16 & 0xFF) / 255.0, (c >> 8 & 0xFF) / 255.0, (c & 0xFF) / 255.0] : null;

    private static int Pack(double[] rgb)
    {
        int Channel(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);
        return Channel(rgb[0]) << 16 | Channel(rgb[1]) << 8 | Channel(rgb[2]);
    }

    private static void Transform(ref double[] rgb, string name, double fraction, double raw)
    {
        switch (name)
        {
            case "lumMod": case "lumOff": case "lum": case "satMod": case "satOff": case "sat": case "hueMod": case "hueOff": case "hue":
                var (h, s, l) = ToHsl(rgb);
                switch (name)
                {
                    case "lumMod": l *= fraction; break;
                    case "lumOff": l += fraction; break;
                    case "lum": l = fraction; break;
                    case "satMod": s *= fraction; break;
                    case "satOff": s += fraction; break;
                    case "sat": s = fraction; break;
                    case "hueMod": h *= fraction; break;
                    case "hueOff": h += raw / 60000; break;
                    default: h = raw / 60000; break;
                }
                rgb = FromHsl(h - Math.Floor(h / 360) * 360, Math.Clamp(s, 0, 1), Math.Clamp(l, 0, 1));
                break;
            case "tint":
                for (int i = 0; i < 3; i++) rgb[i] = Math.Pow(1 - (1 - Math.Pow(rgb[i], Gamma)) * Math.Clamp(fraction, 0, 1), 1 / Gamma);
                break;
            case "shade":
                for (int i = 0; i < 3; i++) rgb[i] = Math.Pow(Math.Pow(rgb[i], Gamma) * Math.Clamp(fraction, 0, 1), 1 / Gamma);
                break;
            case "comp":
                var (ch, cs, cl) = ToHsl(rgb);
                rgb = FromHsl((ch + 180) % 360, cs, cl);
                break;
            case "inv":
                rgb = [1 - rgb[0], 1 - rgb[1], 1 - rgb[2]];
                break;
            case "gray":
                double y = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
                rgb = [y, y, y];
                break;
        }
    }

    // Hue in degrees, saturation and lightness 0 to 1.
    private static (double H, double S, double L) ToHsl(double[] c)
    {
        double max = Math.Max(c[0], Math.Max(c[1], c[2])), min = Math.Min(c[0], Math.Min(c[1], c[2]));
        double l = (max + min) / 2, d = max - min;
        if (d == 0) return (0, 0, l);
        double s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        double h = max == c[0] ? (c[1] - c[2]) / d + (c[1] < c[2] ? 6 : 0) : max == c[1] ? (c[2] - c[0]) / d + 2 : (c[0] - c[1]) / d + 4;
        return (h * 60, s, l);
    }

    private static double[] FromHsl(double h, double s, double l)
    {
        if (s == 0) return [l, l, l];
        double q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
        double Part(double t)
        {
            t -= Math.Floor(t);
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
        }
        return [Part(h / 360 + 1.0 / 3), Part(h / 360), Part(h / 360 - 1.0 / 3)];
    }
}
