namespace LazyPDF.Core.Office;

/// <summary>A spacing as the file states it: a percentage of the line (1 is 100 percent) or points.</summary>
internal readonly record struct PptxSpacing(double Value, bool Points);

/// <summary>Run formatting as one layer states it; null is "not said".</summary>
internal sealed class PptxRunProps
{
    public string? Family;
    public double? Size;
    public bool? Bold, Italic, Underline, Strike, Caps, Link;
    public int? Color, Highlight;
    /// <summary>Percent of the size; positive is superscript.</summary>
    public double? Baseline;

    public PptxRunProps Copy() => (PptxRunProps)MemberwiseClone();

    public void Apply(XmlElement? rPr, PptxColors colors)
    {
        if (rPr is null) return;
        if (DocxReader.Number(rPr.Attribute("sz")) is > 0 and var size) Size = Math.Clamp(size / 100, 1, 1000);
        Bold = Flag(rPr.Attribute("b")) ?? Bold;
        Italic = Flag(rPr.Attribute("i")) ?? Italic;
        if (rPr.Attribute("u") is { } underline) Underline = underline != "none";
        if (rPr.Attribute("strike") is { } strike) Strike = strike != "noStrike";
        if (rPr.Attribute("cap") is { } caps) Caps = caps == "all";
        if (DocxReader.Number(rPr.Attribute("baseline")) is { } baseline) Baseline = Math.Clamp(baseline / 1000, -100, 100);
        foreach (var e in rPr.Elements())
        {
            if (e.Uri != DocxReader.A) continue;
            switch (e.Name)
            {
                case "solidFill":
                    Color = colors.First(e) ?? Color;
                    break;
                case "gradFill":
                    Color = colors.First(e.Child(DocxReader.A, "gsLst")?.Child(DocxReader.A, "gs")) ?? Color;
                    break;
                case "highlight":
                    Highlight = colors.First(e) ?? Highlight;
                    break;
                case "latin":
                    Family = PptxStyle.Font(e.Attribute("typeface"), colors) ?? Family;
                    break;
                case "hlinkClick":
                    Link = true;
                    break;
            }
        }
    }

    internal static bool? Flag(string? value) => value switch { "1" or "true" => true, "0" or "false" => false, _ => null };
}

/// <summary>Formatting of one outline level as the layers state it, laid over each other with <see cref="Apply"/>.</summary>
internal sealed class PptxLevelProps
{
    public LayoutAlign? Align;
    public double? MarL, Indent;
    public PptxSpacing? Line, Before, After;
    /// <summary>none, char or auto.</summary>
    public string? BulletKind;
    public string? BulletChar, BulletFont, AutoType;
    public int? AutoStart, BulletColor;
    public double? BulletPercent, BulletPoints;
    public PptxRunProps Run = new();

    public PptxLevelProps Copy()
    {
        var copy = (PptxLevelProps)MemberwiseClone();
        copy.Run = Run.Copy();
        return copy;
    }

    public void Apply(XmlElement? pPr, PptxColors colors)
    {
        if (pPr is null) return;
        if (DocxReader.Number(pPr.Attribute("marL")) is { } left) MarL = Emu(left);
        if (DocxReader.Number(pPr.Attribute("indent")) is { } indent) Indent = Emu(indent);
        Align = pPr.Attribute("algn") switch
        {
            "l" => LayoutAlign.Left,
            "ctr" => LayoutAlign.Center,
            "r" => LayoutAlign.Right,
            "just" or "justLow" or "dist" or "thaiDist" => LayoutAlign.Justify,
            _ => Align,
        };
        foreach (var e in pPr.Elements())
        {
            if (e.Uri != DocxReader.A) continue;
            switch (e.Name)
            {
                case "lnSpc": Line = Spacing(e) ?? Line; break;
                case "spcBef": Before = Spacing(e) ?? Before; break;
                case "spcAft": After = Spacing(e) ?? After; break;
                case "buNone": BulletKind = "none"; break;
                case "buChar":
                    if (e.Attribute("char") is { Length: > 0 } c)
                    {
                        BulletKind = "char";
                        BulletChar = c;
                    }
                    break;
                case "buAutoNum":
                    BulletKind = "auto";
                    AutoType = e.Attribute("type") ?? "arabicPeriod";
                    AutoStart = DocxReader.Number(e.Attribute("startAt")) is { } start ? (int)Math.Clamp(start, 1, 32767) : 1;
                    break;
                case "buFont": BulletFont = PptxStyle.Font(e.Attribute("typeface"), colors); break;
                case "buFontTx": BulletFont = null; break;
                case "buClr": BulletColor = colors.First(e); break;
                case "buClrTx": BulletColor = null; break;
                case "buSzPct":
                    BulletPercent = Math.Clamp((DocxReader.Number(e.Attribute("val")) ?? 100_000) / 100_000, 0.25, 4);
                    BulletPoints = null;
                    break;
                case "buSzPts":
                    BulletPoints = Math.Clamp((DocxReader.Number(e.Attribute("val")) ?? 1000) / 100, 1, 1000);
                    BulletPercent = null;
                    break;
                case "buSzTx":
                    BulletPercent = BulletPoints = null;
                    break;
                case "defRPr": Run.Apply(e, colors); break;
            }
        }
    }

    private static double Emu(double v) => Math.Clamp(v / 12700, -PptxLimits.MaxSide, PptxLimits.MaxSide);

    private static PptxSpacing? Spacing(XmlElement e)
    {
        if (e.Child(DocxReader.A, "spcPct") is { } percent && DocxReader.Number(percent.Attribute("val")) is { } p) return new PptxSpacing(Math.Clamp(p / 100_000, 0, 132), false);
        if (e.Child(DocxReader.A, "spcPts") is { } points && DocxReader.Number(points.Attribute("val")) is { } pt) return new PptxSpacing(Math.Clamp(pt / 100, 0, 1584), true);
        return null;
    }
}

/// <summary>The body properties of a shape as the layers state them, and the autofit that was stored.</summary>
internal sealed class PptxBodyProps
{
    public double? Left, Top, Right, Bottom;
    public LayoutVAlign? Anchor;
    public bool? Wrap;
    public bool Rotated;
    public double FontScale = 1, LineReduction;

    public void Apply(XmlElement? bodyPr)
    {
        if (bodyPr is null) return;
        Left = Inset(bodyPr, "lIns") ?? Left;
        Top = Inset(bodyPr, "tIns") ?? Top;
        Right = Inset(bodyPr, "rIns") ?? Right;
        Bottom = Inset(bodyPr, "bIns") ?? Bottom;
        Anchor = bodyPr.Attribute("anchor") switch { "t" => LayoutVAlign.Top, "ctr" => LayoutVAlign.Center, "b" => LayoutVAlign.Bottom, "just" or "dist" => LayoutVAlign.Top, _ => Anchor };
        Wrap = bodyPr.Attribute("wrap") switch { "none" => false, "square" => true, _ => Wrap };
        if (bodyPr.Attribute("vert") is { } vert) Rotated = vert != "horz";
        if (DocxReader.Number(bodyPr.Attribute("rot")) is { } rot && rot != 0) Rotated = true;
        foreach (var e in bodyPr.Elements())
        {
            if (e.Uri != DocxReader.A) continue;
            if (e.Name == "normAutofit")
            {
                FontScale = Math.Clamp((DocxReader.Number(e.Attribute("fontScale")) ?? 100_000) / 100_000, 0.1, 1);
                LineReduction = Math.Clamp((DocxReader.Number(e.Attribute("lnSpcReduction")) ?? 0) / 100_000, 0, 0.9);
            }
            else if (e.Name is "noAutofit" or "spAutoFit")
            {
                FontScale = 1;
                LineReduction = 0;
            }
        }
    }

    private static double? Inset(XmlElement e, string name) =>
        DocxReader.Number(e.Attribute(name)) is { } v ? Math.Clamp(v / 12700, 0, PptxLimits.MaxSide) : null;
}

internal static class PptxStyle
{
    /// <summary>A typeface name; +mj-lt and +mn-lt are the theme's heading and body fonts, other theme references name nothing.</summary>
    public static string? Font(string? typeface, PptxColors colors)
    {
        if (string.IsNullOrEmpty(typeface)) return null;
        if (typeface[0] != '+') return typeface;
        return typeface switch { "+mj-lt" => colors.Theme.Font("major"), "+mn-lt" => colors.Theme.Font("minor"), _ => null };
    }
}
