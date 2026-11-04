namespace LazyPDF.Core;

/// <summary>A colour as 8-bit sRGB, converted without profiles (CMYK as (1-c)(1-k)).</summary>
public readonly record struct RgbColor(byte R, byte G, byte B);

/// <summary>A colour space (ISO 32000-1 8.6) as a content stream selects it.</summary>
public sealed class ColorSpaceInfo
{
    private const int MaxDepth = 8;

    private ColorSpaceInfo(string family, int components, PdfObject? definition, ColorSpaceInfo? baseSpace, SampleColorSpace? converter)
    {
        Family = family;
        Components = components;
        Definition = definition;
        Base = baseSpace;
        Converter = converter;
    }

    public static readonly ColorSpaceInfo DeviceGray = Device("DeviceGray", 1);
    public static readonly ColorSpaceInfo DeviceRgb = Device("DeviceRGB", 3);
    public static readonly ColorSpaceInfo DeviceCmyk = Device("DeviceCMYK", 4);

    /// <summary>DeviceGray, DeviceRGB, DeviceCMYK, CalGray, CalRGB, Lab, ICCBased, Indexed, Separation, DeviceN or Pattern.</summary>
    public string Family { get; }

    /// <summary>Numbers a colour of this space has; for Pattern those of the underlying space (0 when it has none).</summary>
    public int Components { get; }

    /// <summary>The name or array as resolved from the file; null for a device space selected by name.</summary>
    public PdfObject? Definition { get; }

    /// <summary>The underlying space of an uncoloured pattern space.</summary>
    public ColorSpaceInfo? Base { get; }

    internal SampleColorSpace? Converter { get; }

    private static ColorSpaceInfo Device(string family, int components) =>
        new(family, components, null, null, SampleColorSpace.Parse(new PdfName(family), v => v, _ => []));

    internal static ColorSpaceInfo Create(PdfDocument document, PdfObject? value, int depth = 0)
    {
        value = document.Resolve(value);
        if (depth > MaxDepth) return DeviceGray;
        if (value is PdfName name)
        {
            return name.Value switch
            {
                "DeviceRGB" or "RGB" or "CalRGB" => DeviceRgb,
                "DeviceCMYK" or "CMYK" => DeviceCmyk,
                "Pattern" => new ColorSpaceInfo("Pattern", 0, value, null, null),
                _ => DeviceGray,
            };
        }
        if (value is not PdfArray { Items.Count: > 0 } array || document.Resolve(array.Items[0]) is not PdfName family) return DeviceGray;
        PdfObject? Item(int i) => i < array.Items.Count ? document.Resolve(array.Items[i]) : null;
        if (family.Value == "Pattern")
        {
            var under = array.Items.Count > 1 ? Create(document, array.Items[1], depth + 1) : null;
            return new ColorSpaceInfo("Pattern", under?.Components ?? 0, value, under, null);
        }
        int components = family.Value switch
        {
            "DeviceGray" or "G" or "CalGray" or "Indexed" or "I" or "Separation" => 1,
            "DeviceRGB" or "RGB" or "CalRGB" or "Lab" => 3,
            "DeviceCMYK" or "CMYK" => 4,
            "ICCBased" => Item(1) is PdfStream icc && document.Integer(icc.Dictionary, "N") is long n and (1 or 3 or 4) ? (int)n : 3,
            "DeviceN" => Item(1) is PdfArray names ? Math.Clamp(names.Items.Count, 1, 32) : 1,
            _ => 1,
        };
        string fam = family.Value switch { "G" => "DeviceGray", "RGB" => "DeviceRGB", "CMYK" => "DeviceCMYK", "I" => "Indexed", var f => f };
        SampleColorSpace? converter = null;
        try
        {
            converter = SampleColorSpace.Parse(value, document.Resolve, document.Data);
        }
        catch (PdfReadException)
        {
        }
        return new ColorSpaceInfo(fam, components, value, null, converter);
    }

    /// <summary>The colour every component zero (or one for the tint spaces) gives, what a space starts with (8.6.5.2).</summary>
    public double[] InitialColor() => Family switch
    {
        "DeviceCMYK" => [0, 0, 0, 1],
        "Separation" or "DeviceN" => [.. Enumerable.Repeat(1.0, Components)],
        _ => new double[Components],
    };

    public RgbColor ToRgb(ReadOnlySpan<double> c)
    {
        Span<double> padded = stackalloc double[32];
        c[..Math.Min(c.Length, 32)].CopyTo(padded);
        Span<byte> rgb = stackalloc byte[3];
        var space = Converter ?? (Components switch { 3 => DeviceRgb, 4 => DeviceCmyk, _ => DeviceGray }).Converter!;
        try
        {
            space.ToRgb(padded, rgb);
        }
        catch (PdfReadException)
        {
            return new RgbColor(0, 0, 0);
        }
        return new RgbColor(rgb[0], rgb[1], rgb[2]);
    }
}

/// <summary>
/// A colour set by a colour operator: its space, its numbers, and for a pattern space the pattern
/// (a tiling pattern's stream or a shading pattern's dictionary, resolved). Immutable.
/// </summary>
public sealed class PdfColor(ColorSpaceInfo space, double[] components, PdfName? patternName = null, PdfObject? pattern = null)
{
    private RgbColor? _rgb;

    public static readonly PdfColor Black = new(ColorSpaceInfo.DeviceGray, [0]);

    public ColorSpaceInfo Space { get; } = space;
    public IReadOnlyList<double> Components { get; } = components;
    public PdfName? PatternName { get; } = patternName;
    public PdfObject? Pattern { get; } = pattern;

    /// <summary>The colour as sRGB; for a pattern the underlying colour of an uncoloured pattern, else black.</summary>
    public RgbColor Rgb => _rgb ??= Space.Family == "Pattern"
        ? Space.Base is { } under && components.Length >= under.Components ? under.ToRgb(components) : new RgbColor(0, 0, 0)
        : Space.ToRgb(components);
}

/// <summary>
/// The graphics state (ISO 32000-1 8.4) as it stands while an operator runs, with the text state
/// (9.3). The instance is the interpreter's own and changes as it goes: copy what is needed
/// during the callback.
/// </summary>
public sealed class GraphicsState
{
    /// <summary>Maps the current user space to the space the page content started in.</summary>
    public PdfMatrix Ctm { get; internal set; } = PdfMatrix.Identity;

    /// <summary>The bounding box of the clipping path, in the space the content started in.</summary>
    public PdfRect Clip { get; internal set; }

    public PdfColor FillColor { get; internal set; } = PdfColor.Black;
    public PdfColor StrokeColor { get; internal set; } = PdfColor.Black;

    public double LineWidth { get; internal set; } = 1;
    public int LineCap { get; internal set; }
    public int LineJoin { get; internal set; }
    public double MiterLimit { get; internal set; } = 10;
    public IReadOnlyList<double> Dash { get; internal set; } = [];
    public double DashPhase { get; internal set; }

    public double CharSpacing { get; internal set; }
    public double WordSpacing { get; internal set; }

    /// <summary>/Tz as a fraction: 1 for 100%.</summary>
    public double HorizontalScale { get; internal set; } = 1;

    public double Leading { get; internal set; }
    public PdfFont? Font { get; internal set; }
    public double FontSize { get; internal set; }

    /// <summary>0 fill, 1 stroke, 2 both, 3 invisible, 4 to 7 the same and added to the clip.</summary>
    public int RenderMode { get; internal set; }

    public double Rise { get; internal set; }

    public double FillAlpha { get; internal set; } = 1;
    public double StrokeAlpha { get; internal set; } = 1;
    public string BlendMode { get; internal set; } = "Normal";

    /// <summary>The /SMask of an ExtGState: a dictionary, or null for none.</summary>
    public PdfDictionary? SoftMask { get; internal set; }

    internal GraphicsState Clone() => (GraphicsState)MemberwiseClone();
}
