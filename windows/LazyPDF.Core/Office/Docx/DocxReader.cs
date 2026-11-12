using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>
/// Reads a .docx package into the layout model: body paragraphs and runs with their styles, page setup and sections, headers
/// and footers. What it does not carry over is counted in <see cref="LayoutDocument.Skipped"/>.
/// </summary>
internal sealed class DocxReader
{
    public const string W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    public const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string Mc = "http://schemas.openxmlformats.org/markup-compatibility/2006";
    private const string MathNs = "http://schemas.openxmlformats.org/officeDocument/2006/math";
    private const string StylesType = R + "/styles";
    private const string ThemeType = R + "/theme";
    private const string NumberingType = R + "/numbering";
    private const string HeaderType = R + "/header";
    private const string FooterType = R + "/footer";

    private static readonly Dictionary<string, int> Highlights = new()
    {
        ["black"] = 0x000000, ["blue"] = 0x0000FF, ["cyan"] = 0x00FFFF, ["green"] = 0x00FF00, ["magenta"] = 0xFF00FF, ["red"] = 0xFF0000,
        ["yellow"] = 0xFFFF00, ["white"] = 0xFFFFFF, ["darkBlue"] = 0x000080, ["darkCyan"] = 0x008080, ["darkGreen"] = 0x008000,
        ["darkMagenta"] = 0x800080, ["darkRed"] = 0x800000, ["darkYellow"] = 0x808000, ["darkGray"] = 0x808080, ["lightGray"] = 0xC0C0C0,
    };

    private sealed class Field
    {
        public StringBuilder Code { get; } = new();
        public bool InResult, Classified, Outer;
        public LayoutField Kind;
        public RunProps Format = new();
    }

    private sealed class Piece(LayoutRun format)
    {
        public LayoutRun Format { get; } = format;
        public StringBuilder Text { get; } = new();
    }

    private readonly OpcPackage _package;
    private readonly CancellationToken _cancellation;
    private readonly SortedDictionary<string, int> _skipped = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (ParaProps, RunProps)> _paragraphStyles = [];
    private readonly Dictionary<string, List<LayoutParagraph>> _bands = new(StringComparer.OrdinalIgnoreCase);
    private DocxStyles _styles = new();
    private DocxTheme _theme = new();
    private DocxNumbering _numbering = new();

    // State of the part being read.
    private List<LayoutBlock> _blocks = [];
    private readonly List<(int At, XmlElement Properties)> _sectionEnds = [];
    private readonly Stack<Field> _fields = new();
    private readonly List<Piece> _pieces = [];
    private bool _inBand;

    private DocxReader(OpcPackage package, CancellationToken cancellation)
    {
        _package = package;
        _cancellation = cancellation;
    }

    public static LayoutDocument Read(byte[] data, CancellationToken cancellation = default)
    {
        if (data.Length >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "This is a Word 97-2003 file. Save it as .docx first.");
        }
        return new DocxReader(OpcPackage.Open(data), cancellation).Run();
    }

    private LayoutDocument Run()
    {
        string main = _package.Relationships("").FirstOrDefault(r => r.Type == OpcPackage.OfficeDocument)?.Target
            ?? throw PdfReadException.Damaged("The file has no main document part.");
        if (!_package.Contains(main)) throw PdfReadException.Damaged($"The package has no part {main}.");
        if (_package.ContentType(main) is not { } type || !type.Contains("wordprocessingml", StringComparison.Ordinal))
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The file is not a Word document.");
        }
        var root = _package.Xml(main);
        var body = root.Uri == W && root.Name == "document" ? root.Child(W, "body") : null;
        if (body is null) throw new PdfReadException(PdfReadProblem.Unsupported, "The document is not in the Word 2007 format.");

        var relationships = _package.Relationships(main);
        _styles = DocxStyles.Read(Part(relationships, StylesType));
        _theme = DocxTheme.Read(Part(relationships, ThemeType));
        _numbering = DocxNumbering.Read(Part(relationships, NumberingType));

        Blocks(body);
        var all = _blocks;
        var ends = _sectionEnds.ToList();
        ends.Add((all.Count, body.Child(W, "sectPr") ?? new XmlElement(W, "sectPr", [])));

        var document = new LayoutDocument();
        int from = 0;
        LayoutSection? previous = null;
        foreach (var (at, properties) in ends)
        {
            var slice = all.GetRange(from, at - from);
            from = at;
            var geometry = Geometry(properties);
            bool continuous = properties.Child(W, "type")?.Attribute(W, "val") == "continuous";
            if (continuous && previous is not null && Same(previous.Page, geometry))
            {
                previous.Blocks.AddRange(slice);
                continue;
            }
            // A section made only of the tail after the last section break has nothing to show.
            if (slice.Count == 0 && previous is not null && properties == ends[^1].Properties) continue;
            var section = new LayoutSection
            {
                Page = geometry,
                Header = Band(properties, relationships, HeaderType, "headerReference", previous?.Header),
                Footer = Band(properties, relationships, FooterType, "footerReference", previous?.Footer),
                Blocks = slice,
            };
            if (properties.Child(W, "titlePg") is { } title && On(title) && properties.Elements(W, "headerReference").Concat(properties.Elements(W, "footerReference")).Any(e => e.Attribute(W, "type") == "first"))
            {
                Skip("header-variant");
            }
            document.Sections.Add(section);
            previous = section;
        }
        if (document.Sections.Count == 0) document.Sections.Add(new LayoutSection { Blocks = all });
        foreach (var (kind, count) in _skipped) document.Skipped.Add(new SkippedFeature(kind, count));
        return document;
    }

    private XmlElement? Part(IReadOnlyList<OpcRelationship> relationships, string type)
    {
        string? target = relationships.FirstOrDefault(r => r.Type == type)?.Target;
        return target is not null && _package.Contains(target) ? _package.Xml(target) : null;
    }

    private void Skip(string kind) => _skipped[kind] = _skipped.GetValueOrDefault(kind) + 1;

    private static bool Same(LayoutGeometry a, LayoutGeometry b) =>
        a.Width == b.Width && a.Height == b.Height && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom && a.Left == b.Left
        && a.HeaderDistance == b.HeaderDistance && a.FooterDistance == b.FooterDistance;

    private static LayoutGeometry Geometry(XmlElement sectPr)
    {
        var size = sectPr.Child(W, "pgSz");
        double width = Points(size, "w") ?? 612, height = Points(size, "h") ?? 792;
        if (size?.Attribute(W, "orient") == "landscape" && width < height) (width, height) = (height, width);
        var margin = sectPr.Child(W, "pgMar");
        return new LayoutGeometry
        {
            Width = width,
            Height = height,
            Top = Math.Abs(Points(margin, "top") ?? 72),
            Right = Points(margin, "right") ?? 72,
            Bottom = Math.Abs(Points(margin, "bottom") ?? 72),
            Left = (Points(margin, "left") ?? 72) + (Points(margin, "gutter") ?? 0),
            HeaderDistance = Points(margin, "header") ?? 36,
            FooterDistance = Points(margin, "footer") ?? 36,
        };
    }

    private static double? Points(XmlElement? e, string name) => Number(e?.Attribute(W, name)) is { } twips ? twips / 20 : null;

    // A section without its own header or footer shows the previous section's, as in Word.
    private List<LayoutParagraph> Band(XmlElement sectPr, IReadOnlyList<OpcRelationship> relationships, string type, string reference, List<LayoutParagraph>? inherited)
    {
        string? id = sectPr.Elements(W, reference).FirstOrDefault(e => (e.Attribute(W, "type") ?? "default") == "default")?.Attribute(R, "id");
        string? target = id is null ? null : relationships.FirstOrDefault(r => r.Id == id && r.Type == type)?.Target;
        if (target is null || !_package.Contains(target)) return inherited ?? [];
        if (_bands.TryGetValue(target, out var known)) return known;

        _blocks = [];
        _fields.Clear();
        _inBand = true;
        Blocks(_package.Xml(target));
        _inBand = false;
        return _bands[target] = [.. _blocks.OfType<LayoutParagraph>()];
    }

    // ---- block level ----

    private void Blocks(XmlElement container)
    {
        foreach (var e in container.Elements())
        {
            _cancellation.ThrowIfCancellationRequested();
            if (e.Uri == Mc && e.Name == "AlternateContent")
            {
                if (Pick(e) is { } picked) Blocks(picked);
                continue;
            }
            if (e.Uri != W) continue;
            switch (e.Name)
            {
                case "p": Paragraph(e); break;
                case "tbl":
                    // Tables are read as their paragraphs in order until table layout exists.
                    Skip("table");
                    foreach (var cell in e.Elements(W, "tr").SelectMany(row => row.Elements(W, "tc"))) Blocks(cell);
                    break;
                case "sdt":
                    if (e.Child(W, "sdtContent") is { } content) Blocks(content);
                    break;
                case "ins":
                case "moveTo":
                    Skip("tracked-change");
                    Blocks(e);
                    break;
                case "del":
                case "moveFrom":
                    Skip("tracked-change");
                    break;
                case "customXml":
                    Blocks(e);
                    break;
            }
        }
    }

    private static XmlElement? Pick(XmlElement alternate) =>
        alternate.Elements(Mc, "Choice").FirstOrDefault() ?? alternate.Elements(Mc, "Fallback").FirstOrDefault();

    private void Paragraph(XmlElement p)
    {
        var pPr = p.Child(W, "pPr");
        string? styleId = pPr?.Child(W, "pStyle")?.Attribute(W, "val");
        if (!_paragraphStyles.TryGetValue(styleId ?? "", out var known))
        {
            known = _paragraphStyles[styleId ?? ""] = _styles.Paragraph(styleId, _theme);
        }
        var props = known.Item1.Copy();
        props.Apply(pPr);
        var mark = known.Item2.Copy();
        mark.Apply(pPr?.Child(W, "rPr"), _theme);

        // The level's indents sit between the style and the paragraph's own.
        NumberLabel? label = props.NumId is > 0 and var numId ? _numbering.Next(numId, props.Ilvl, styleId) : null;
        if (label is not null)
        {
            props = known.Item1.Copy();
            props.Apply(label.PPr);
            props.Apply(pPr);
        }

        _pieces.Clear();
        if (label is not null) Label(label, mark);
        bool first = true;
        void Emit(bool last)
        {
            var runs = Runs(mark, last);
            if (runs is null) return;
            _blocks.Add(Make(props, runs, first && props.PageBreakBefore == true, label?.Suffix == "tab" ? label.TabStop : null));
            first = false;
        }
        _breaker = () =>
        {
            Emit(false);
            first = false;
            _blocks.Add(new LayoutPageBreak());
        };
        Inline(p, known.Item2);
        Emit(true);
        _breaker = null;
        if (pPr?.Child(W, "sectPr") is { } sectPr && !_inBand) _sectionEnds.Add((_blocks.Count, sectPr));
    }

    private Action? _breaker;

    // The runs collected so far, or null for the part of a paragraph before a page break that has no text.
    private List<LayoutRun>? Runs(RunProps mark, bool last)
    {
        var runs = new List<LayoutRun>();
        foreach (var piece in _pieces)
        {
            if (piece.Text.Length == 0 && piece.Format.Field == LayoutField.None) continue;
            runs.Add(Rebuild(piece.Format, piece.Text.ToString()));
        }
        _pieces.Clear();
        if (runs.Count > 0) return runs;
        // Nothing to show: an empty line takes the height of the paragraph mark. A part before a page break is not a line at all.
        return last ? [Rebuild(Format(mark, "", LayoutField.None), "")] : null;
    }

    private static LayoutRun Rebuild(LayoutRun f, string text) => new()
    {
        Text = text, Family = f.Family, Size = f.Size, Bold = f.Bold, Italic = f.Italic, Underline = f.Underline, Strike = f.Strike,
        Color = f.Color, Highlight = f.Highlight, Shift = f.Shift, Field = f.Field,
    };

    private void Label(NumberLabel label, RunProps mark)
    {
        if (label.Text.Length == 0 && label.Suffix == "nothing") return;
        var props = mark.Copy();
        props.Apply(label.RPr, _theme);
        if (label.SymbolFont is not null) props.Family = mark.Family;
        string text = label.Text + label.Suffix switch { "nothing" => "", "space" => " ", _ => "	" };
        var piece = new Piece(Format(props, text, LayoutField.None));
        piece.Text.Append(text);
        _pieces.Add(piece);
    }

    private static LayoutParagraph Make(ParaProps p, List<LayoutRun> runs, bool pageBreakBefore, double? labelTab)
    {
        var rule = p.LineRule switch { "exact" => LineRule.Exact, "atLeast" => LineRule.AtLeast, _ => LineRule.Multiple };
        double spacing = 1;
        if (p.Line is > 0 and var line)
        {
            spacing = rule == LineRule.Multiple ? Math.Min(line / 240, 132) : Math.Clamp(line / 20, 1, 1584);
        }
        else rule = LineRule.Multiple;
        return new LayoutParagraph
        {
            Runs = runs,
            Align = p.Align ?? LayoutAlign.Left,
            Left = p.Left ?? 0,
            Right = p.Right ?? 0,
            FirstLine = p.First ?? 0,
            Before = Math.Max(0, p.Before ?? 0),
            After = Math.Max(0, p.After ?? 0),
            LineSpacing = spacing,
            Rule = rule,
            KeepWithNext = p.KeepNext == true,
            PageBreakBefore = pageBreakBefore,
            WidowControl = p.Widow != false,
            LabelTab = labelTab,
        };
    }

    // ---- inline level ----

    private void Inline(XmlElement parent, RunProps paragraphRun)
    {
        foreach (var e in parent.Elements())
        {
            _cancellation.ThrowIfCancellationRequested();
            if (e.Uri == Mc && e.Name == "AlternateContent")
            {
                if (Pick(e) is { } picked) Inline(picked, paragraphRun);
                continue;
            }
            if (e.Uri == MathNs)
            {
                if (e.Name is "oMath" or "oMathPara") Skip("equation");
                continue;
            }
            if (e.Uri != W) continue;
            switch (e.Name)
            {
                case "r": Run(e, paragraphRun); break;
                case "hyperlink":
                case "smartTag":
                case "customXml":
                case "dir":
                case "bdo":
                    Inline(e, paragraphRun);
                    break;
                case "sdt":
                    if (e.Child(W, "sdtContent") is { } content) Inline(content, paragraphRun);
                    break;
                case "ins":
                case "moveTo":
                    Skip("tracked-change");
                    Inline(e, paragraphRun);
                    break;
                case "del":
                case "moveFrom":
                    Skip("tracked-change");
                    break;
                case "fldSimple":
                    var simple = new Field { InResult = true, Outer = _fields.Count == 0, Format = paragraphRun.Copy() };
                    simple.Code.Append(e.Attribute(W, "instr"));
                    Classify(simple);
                    _fields.Push(simple);
                    Inline(e, paragraphRun);
                    _fields.Pop();
                    break;
            }
        }
    }

    private void Run(XmlElement r, RunProps paragraphRun)
    {
        var props = paragraphRun.Copy();
        _styles.Character(r.Child(W, "rPr")?.Child(W, "rStyle")?.Attribute(W, "val"), props, _theme);
        props.Apply(r.Child(W, "rPr"), _theme);
        Content(r, props);
    }

    private void Content(XmlElement run, RunProps props)
    {
        foreach (var e in run.Elements())
        {
            if (e.Uri == Mc && e.Name == "AlternateContent")
            {
                if (Pick(e) is { } picked) Content(picked, props);
                continue;
            }
            if (e.Uri != W) continue;
            switch (e.Name)
            {
                case "t": Text(props, e.Text); break;
                case "tab":
                case "ptab": Text(props, "\t"); break;
                case "cr": Text(props, "\n"); break;
                case "noBreakHyphen": Text(props, "‑"); break;
                case "br":
                    string? kind = e.Attribute(W, "type");
                    if (kind is "page" or "column" && !_inBand && Visible(props)) _breaker?.Invoke();
                    else Text(props, "\n");
                    break;
                case "instrText":
                    if (_fields.TryPeek(out var open) && !open.InResult) open.Code.Append(e.Text);
                    break;
                case "fldChar": FieldChar(e.Attribute(W, "fldCharType"), props); break;
                case "drawing": if (Visible(props)) Skip(Drawing(e, "drawing")); break;
                case "pict": if (Visible(props)) Skip(Drawing(e, "shape")); break;
                case "object": if (Visible(props)) Skip("drawing"); break;
                case "footnoteReference": Skip("footnote"); break;
                case "endnoteReference": Skip("endnote"); break;
                case "commentReference": Skip("comment"); break;
            }
        }
    }

    private bool Visible(RunProps props) => props.Hidden != true && !Suppressed;

    private bool Suppressed => _fields.Any(f => !f.InResult || f.Kind != LayoutField.None);

    private static string Drawing(XmlElement e, string fallback)
    {
        bool text = false, chart = false, picture = false, shape = false;
        void Walk(XmlElement x)
        {
            if (x.Uri == Mc && x.Name == "AlternateContent")
            {
                if (Pick(x) is { } picked) Walk(picked);
                return;
            }
            switch (x.Name)
            {
                case "txbxContent": case "textbox": text = true; break;
                case "pic": case "imagedata": picture = true; break;
                case "wsp": shape = true; break;
                case "graphicData":
                    string uri = x.Attribute("uri") ?? "";
                    if (uri.EndsWith("/chart", StringComparison.Ordinal)) chart = true;
                    else if (uri.EndsWith("/picture", StringComparison.Ordinal)) picture = true;
                    break;
            }
            foreach (var child in x.Elements()) Walk(child);
        }
        Walk(e);
        return text ? "text-box" : chart ? "chart" : picture ? "picture" : shape ? "shape" : fallback;
    }

    // ---- fields ----

    private void FieldChar(string? type, RunProps props)
    {
        switch (type)
        {
            case "begin":
                _fields.Push(new Field { Outer = _fields.Count == 0, Format = props.Copy() });
                break;
            case "separate":
                if (_fields.TryPeek(out var field))
                {
                    field.InResult = true;
                    Classify(field);
                }
                break;
            case "end":
                if (_fields.TryPop(out var done)) Classify(done);
                break;
        }
    }

    // PAGE and NUMPAGES in a header or footer become field runs; every other field keeps the text it last showed.
    private void Classify(Field field)
    {
        if (field.Classified) return;
        field.Classified = true;
        string code = field.Code.ToString().Trim();
        int space = code.IndexOfAny([' ', '\t', '\r', '\n']);
        string name = Upper(space < 0 ? code : code[..space]);
        if (name is "PAGE" or "NUMPAGES")
        {
            if (!_inBand) return;
            field.Kind = name == "PAGE" ? LayoutField.PageNumber : LayoutField.PageCount;
            Add(field.Format, "", field.Kind);
        }
        else if (field.Outer && name != "HYPERLINK" && name.Length > 0) Skip("field");
    }

    // ---- text ----

    private void Text(RunProps props, string text)
    {
        if (text.Length == 0 || !Visible(props)) return;
        if (props.Caps == true) text = Upper(text);
        Add(props, text, LayoutField.None);
    }

    // Plain ASCII only: full case mapping differs between the platforms.
    private static string Upper(string text)
    {
        var chars = text.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
        {
            if (chars[i] is >= 'a' and <= 'z') chars[i] = (char)(chars[i] - 32);
        }
        return new string(chars);
    }

    private void Add(RunProps props, string text, LayoutField field)
    {
        var format = Format(props, text, field);
        if (field == LayoutField.None && _pieces.Count > 0 && Same(_pieces[^1].Format, format))
        {
            _pieces[^1].Text.Append(text);
            return;
        }
        var piece = new Piece(format);
        piece.Text.Append(text);
        _pieces.Add(piece);
    }

    private static bool Same(LayoutRun a, LayoutRun b) =>
        a.Field == LayoutField.None && b.Field == LayoutField.None && a.Family == b.Family && a.Size == b.Size && a.Bold == b.Bold
        && a.Italic == b.Italic && a.Underline == b.Underline && a.Strike == b.Strike && a.Color == b.Color && a.Highlight == b.Highlight && a.Shift == b.Shift;

    private static LayoutRun Format(RunProps p, string text, LayoutField field)
    {
        double size = p.Size ?? 10;
        double shift = 0;
        if (p.Vertical == 1) { shift = size * 0.33; size *= 2.0 / 3; }
        else if (p.Vertical == -1) { shift = -size * 0.14; size *= 2.0 / 3; }
        return new LayoutRun
        {
            Text = text,
            Family = p.Family ?? "Times New Roman",
            Size = size,
            Bold = p.Bold == true,
            Italic = p.Italic == true,
            Underline = p.Underline == true,
            Strike = p.Strike == true,
            Color = p.Color ?? 0,
            Highlight = p.Highlight is >= 0 ? p.Highlight : null,
            Shift = shift,
            Field = field,
        };
    }

    // ---- values ----

    public static bool On(XmlElement e) => e.Attribute(W, "val") is not ("0" or "false" or "off");

    public static double? Number(string? text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) && double.IsFinite(v) ? v : null;

    public static int? Hex(string? text) =>
        text is { Length: 6 } && int.TryParse(text, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int rgb) ? rgb : null;

    public static int? HighlightColor(string name) => Highlights.TryGetValue(name, out int rgb) ? rgb : null;
}
