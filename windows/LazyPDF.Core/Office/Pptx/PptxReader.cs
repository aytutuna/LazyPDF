namespace LazyPDF.Core.Office;

/// <summary>
/// Reads a .pptx package into a <see cref="PptxPresentation"/>: the slides in order with their background and the shapes that
/// can be drawn, positioned in points and with text resolved through slide, layout, master and presentation defaults. Hidden
/// slides are left out. What it does not carry over is counted in <see cref="PptxPresentation.Skipped"/>.
/// </summary>
internal sealed partial class PptxReader
{
    public const string P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string Mc = "http://schemas.openxmlformats.org/markup-compatibility/2006";
    private const double EmuPerPoint = 12700;
    private const double DefaultWidth = 720, DefaultHeight = 540;

    private sealed class Placeholder(string? type, int index, XmlElement shape)
    {
        public string? Type { get; } = type;
        public int Index { get; } = index;
        public XmlElement Shape { get; } = shape;
        public string Group { get; } = GroupOf(type);
    }

    // A slide master or a slide layout, read once however many slides use it.
    private sealed class Template
    {
        public required string Name { get; init; }
        public required XmlElement Root { get; init; }
        public required IReadOnlyList<OpcRelationship> Relationships { get; init; }
        public required PptxColors Colors { get; init; }
        public required List<Placeholder> Placeholders { get; init; }
        public Template? Master { get; init; }
        public XmlElement? Theme { get; init; }
        public bool ShowMasterShapes { get; init; } = true;
        // The layout's own shapes and the master's as they come out under this layout's color map.
        public List<PptxShape>? Shapes, MasterShapes;
    }

    private sealed record Scope(Template? Layout, Template Master, PptxColors Colors, bool IsSlide, IReadOnlyList<OpcRelationship> Relationships);

    private readonly OpcPackage _package;
    private readonly PptxLimits _limits;
    private readonly CancellationToken _cancellation;
    private readonly SortedDictionary<string, int> _skipped = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Template> _masters = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Template> _layouts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, byte[]> _pictures = new(StringComparer.OrdinalIgnoreCase);
    private XmlElement? _defaultStyle;
    private double _width = DefaultWidth, _height = DefaultHeight;
    private long _totalText, _drawn;
    private int _pictureCount;

    private PptxReader(OpcPackage package, PptxLimits limits, CancellationToken cancellation)
    {
        _package = package;
        _limits = limits;
        _cancellation = cancellation;
    }

    public static PptxPresentation Read(byte[] data, PptxLimits? limits = null, CancellationToken cancellation = default)
    {
        if (data.Length >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "This is a PowerPoint 97-2003 file. Save it as .pptx first.");
        }
        return new PptxReader(OpcPackage.Open(data), limits ?? PptxLimits.Default, cancellation).Run();
    }

    private PptxPresentation Run()
    {
        string main = _package.Relationships("").FirstOrDefault(r => r.Type == OpcPackage.OfficeDocument)?.Target
            ?? throw PdfReadException.Damaged("The file has no main presentation part.");
        if (!_package.Contains(main)) throw PdfReadException.Damaged($"The package has no part {main}.");
        if (_package.ContentType(main) is not { } type || !type.Contains("presentationml", StringComparison.Ordinal))
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The file is not a PowerPoint presentation.");
        }
        var root = _package.Xml(main);
        if (root.Uri != P || root.Name != "presentation") throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation is not in the PowerPoint 2007 format.");

        var size = root.Child(P, "sldSz");
        _width = Side(size, "cx", DefaultWidth);
        _height = Side(size, "cy", DefaultHeight);
        _defaultStyle = root.Child(P, "defaultTextStyle");
        int first = (int)Math.Clamp(DocxReader.Number(root.Attribute("firstSlideNum")) ?? 1, 0, 32767);

        var relationships = _package.Relationships(main);
        var ids = root.Child(P, "sldIdLst")?.Elements(P, "sldId").ToList() ?? [];
        if (ids.Count > _limits.MaxSlides) throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation has too many slides.");

        var presentation = new PptxPresentation { Width = _width, Height = _height };
        for (int i = 0; i < ids.Count; i++)
        {
            _cancellation.ThrowIfCancellationRequested();
            string? id = ids[i].Attribute(R, "id");
            string? target = relationships.FirstOrDefault(r => r.Id == id && r.Type.EndsWith("/slide", StringComparison.Ordinal))?.Target;
            if (target is null || !_package.Contains(target)) continue;
            var slide = _package.Xml(target);
            if (slide.Uri != P || slide.Name != "sld") continue;
            if (slide.Attribute("show") is "0" or "false")
            {
                Skip(PptxSkipped.HiddenSlide);
                continue;
            }
            presentation.Slides.Add(Slide(slide, target, first + i));
        }
        if (presentation.Slides.Count == 0) throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation has no slides to show.");
        foreach (var (kind, count) in _skipped) presentation.Skipped.Add(new SkippedFeature(kind, count));
        return presentation;
    }

    private static double Side(XmlElement? size, string name, double fallback) =>
        DocxReader.Number(size?.Attribute(name)) is > 0 and var emu ? Math.Clamp(emu / EmuPerPoint, PptxLimits.MinSide, PptxLimits.MaxSide) : fallback;

    private void Skip(string kind, int count = 1) => _skipped[kind] = _skipped.GetValueOrDefault(kind) + count;

    // ---- masters and layouts ----

    private Template Master(string? part)
    {
        part ??= "";
        if (_masters.TryGetValue(part, out var known)) return known;
        var root = part.Length > 0 && _package.Contains(part) ? _package.Xml(part) : new XmlElement(P, "sldMaster", []);
        var relationships = part.Length > 0 && _package.Contains(part) ? _package.Relationships(part) : [];
        string? themePart = relationships.FirstOrDefault(r => r.Type.EndsWith("/theme", StringComparison.Ordinal))?.Target;
        var themeRoot = themePart is not null && _package.Contains(themePart) ? _package.Xml(themePart) : null;
        var colors = new PptxColors(DocxTheme.Read(themeRoot), PptxColors.ReadMap(root.Child(P, "clrMap")));
        return _masters[part] = new Template
        {
            Name = part, Root = root, Relationships = relationships, Colors = colors, Theme = themeRoot, Placeholders = Placeholders(root),
        };
    }

    private Template Layout(string? part)
    {
        part ??= "";
        if (_layouts.TryGetValue(part, out var known)) return known;
        var root = part.Length > 0 && _package.Contains(part) ? _package.Xml(part) : new XmlElement(P, "sldLayout", []);
        var relationships = part.Length > 0 && _package.Contains(part) ? _package.Relationships(part) : [];
        var master = Master(relationships.FirstOrDefault(r => r.Type.EndsWith("/slideMaster", StringComparison.Ordinal))?.Target);
        return _layouts[part] = new Template
        {
            Name = part, Root = root, Relationships = relationships, Master = master, Theme = master.Theme,
            Colors = Remapped(root, master.Colors), Placeholders = Placeholders(root), ShowMasterShapes = root.Attribute("showMasterSp") is not ("0" or "false"),
        };
    }

    private static PptxColors Remapped(XmlElement root, PptxColors inherited) =>
        root.Child(P, "clrMapOvr")?.Child(DocxReader.A, "overrideClrMapping") is { } over ? inherited.WithMap(PptxColors.ReadMap(over)) : inherited;

    private static XmlElement? Tree(XmlElement root) => root.Child(P, "cSld")?.Child(P, "spTree");

    private static XmlElement? PlaceholderOf(XmlElement shape) => shape.Child(P, "nvSpPr")?.Child(P, "nvPr")?.Child(P, "ph");

    private static List<Placeholder> Placeholders(XmlElement root)
    {
        var list = new List<Placeholder>();
        foreach (var sp in Children(Tree(root)).Where(e => e.Uri == P && e.Name == "sp"))
        {
            if (PlaceholderOf(sp) is not { } ph) continue;
            int index = (int)Math.Clamp(DocxReader.Number(ph.Attribute("idx")) ?? 0, 0, int.MaxValue);
            list.Add(new Placeholder(ph.Attribute("type"), index, sp));
        }
        return list;
    }

    private static string GroupOf(string? type) => type switch
    {
        "title" or "ctrTitle" => "title",
        "dt" => "dt",
        "ftr" => "ftr",
        "sldNum" => "sldNum",
        "hdr" => "hdr",
        _ => "body",
    };

    // A slide placeholder finds its twin in the layout by index first; a layout placeholder finds its twin in the master by kind.
    private static Placeholder? Match(List<Placeholder> list, string? type, int index, bool byIndex)
    {
        string group = GroupOf(type);
        if (byIndex && list.FirstOrDefault(p => p.Index == index && p.Group == group) is { } exact) return exact;
        return list.FirstOrDefault(p => p.Group == group);
    }

    private static IEnumerable<XmlElement> Children(XmlElement? tree)
    {
        foreach (var e in tree?.Elements() ?? [])
        {
            if (e.Uri == Mc && e.Name == "AlternateContent")
            {
                var picked = e.Elements(Mc, "Choice").FirstOrDefault() ?? e.Elements(Mc, "Fallback").FirstOrDefault();
                foreach (var inner in Children(picked)) yield return inner;
            }
            else yield return e;
        }
    }

    // ---- slides ----

    private PptxSlide Slide(XmlElement root, string part, int number)
    {
        var relationships = _package.Relationships(part);
        var layout = Layout(relationships.FirstOrDefault(r => r.Type.EndsWith("/slideLayout", StringComparison.Ordinal))?.Target);
        var master = layout.Master!;
        var colors = Remapped(root, layout.Colors);
        bool overridden = !ReferenceEquals(colors, layout.Colors);

        var shapes = new List<PptxShape>();
        if (root.Attribute("showMasterSp") is not ("0" or "false"))
        {
            if (layout.ShowMasterShapes) shapes.AddRange(Inherited(master, master, colors, overridden, ref layout.MasterShapes));
            shapes.AddRange(Inherited(layout, master, colors, overridden, ref layout.Shapes));
        }
        shapes.AddRange(Shapes(root, new Scope(layout, master, colors, true, relationships), place: true));
        _drawn += shapes.Count;
        if (_drawn > _limits.MaxDrawnShapes) throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation has too many shapes.");

        return new PptxSlide { Number = number, Background = Background(root, relationships, colors, layout, master), Shapes = shapes };
    }

    // A slide that overrides the color map gets its own copy; the others share what the layout cached.
    private List<PptxShape> Inherited(Template source, Template master, PptxColors colors, bool overridden, ref List<PptxShape>? cache)
    {
        if (overridden) return Static(source, new Scope(null, master, colors, false, source.Relationships));
        return cache ??= Static(source, new Scope(null, master, colors, false, source.Relationships));
    }

    private sealed record BackgroundSays(PptxBackground? Value);

    // ---- backgrounds ----

    private PptxBackground? Background(XmlElement slide, IReadOnlyList<OpcRelationship> relationships, PptxColors colors, Template layout, Template master)
    {
        if (Background(slide, relationships, colors, master.Theme) is { } own) return own.Value;
        if (Background(layout.Root, layout.Relationships, colors, master.Theme) is { } inherited) return inherited.Value;
        return Background(master.Root, master.Relationships, colors, master.Theme)?.Value;
    }

    // Null when the part says nothing about its background; else what it says, which may be nothing.
    private BackgroundSays? Background(XmlElement root, IReadOnlyList<OpcRelationship> relationships, PptxColors colors, XmlElement? theme)
    {
        var bg = root.Child(P, "cSld")?.Child(P, "bg");
        if (bg is null) return null;
        if (bg.Child(P, "bgPr") is { } properties)
        {
            foreach (var e in properties.Elements())
            {
                if (e.Uri != DocxReader.A) continue;
                switch (e.Name)
                {
                    case "solidFill": return new BackgroundSays(new PptxBackground(colors.First(e), null));
                    case "gradFill":
                        Skip(PptxSkipped.Gradient);
                        return new BackgroundSays(new PptxBackground(colors.First(e.Child(DocxReader.A, "gsLst")?.Child(DocxReader.A, "gs")), null));
                    case "blipFill": return new BackgroundSays(new PptxBackground(null, Picture(e, relationships, _width, _height)));
                    case "noFill": case "pattFill": case "grpFill": return new BackgroundSays(null);
                }
            }
            return null;
        }
        if (bg.Child(P, "bgRef") is { } reference)
        {
            int? color = colors.First(reference);
            // 1001 and up name an entry of the theme's background fills, which holds the color of the reference as phClr.
            if (DocxReader.Number(reference.Attribute("idx")) is { } idx && idx >= 1001 && color is not null)
            {
                var entry = theme?.Child(DocxReader.A, "themeElements")?.Child(DocxReader.A, "fmtScheme")?.Child(DocxReader.A, "bgFillStyleLst")?.Elements().ElementAtOrDefault((int)idx - 1001);
                if (entry is { Name: "solidFill" }) color = colors.First(entry, color) ?? color;
                else if (entry is { Name: "gradFill" })
                {
                    Skip(PptxSkipped.Gradient);
                    color = colors.First(entry.Child(DocxReader.A, "gsLst")?.Child(DocxReader.A, "gs"), color) ?? color;
                }
            }
            return new BackgroundSays(new PptxBackground(color, null));
        }
        return null;
    }

    // A picture of the given size in points; a missing or linked picture is counted as an unreadable one.
    private LayoutPicture? Picture(XmlElement blipFill, IReadOnlyList<OpcRelationship> relationships, double width, double height)
    {
        string? id = blipFill.Child(DocxReader.A, "blip")?.Attribute(R, "embed");
        string? target = id is null ? null : relationships.FirstOrDefault(r => r.Id == id && r.Type.EndsWith("/image", StringComparison.Ordinal))?.Target;
        if (target is null || !_package.Contains(target))
        {
            Skip(SkippedKinds.UnreadablePicture);
            return null;
        }
        if (++_pictureCount > _limits.MaxPictures)
        {
            Skip(SkippedKinds.UnreadablePicture);
            return null;
        }
        if (!_pictures.TryGetValue(target, out var bytes)) _pictures[target] = bytes = _package.Bytes(target);
        var crop = blipFill.Child(DocxReader.A, "srcRect");
        double Edge(string name) => Math.Clamp((DocxReader.Number(crop?.Attribute(name)) ?? 0) / 100_000, 0, 0.95);
        return new LayoutPicture(bytes, width, height, Edge("l"), Edge("t"), Edge("r"), Edge("b"));
    }
}
