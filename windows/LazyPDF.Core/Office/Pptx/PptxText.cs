using System.Globalization;

namespace LazyPDF.Core.Office;

internal sealed partial class PptxReader
{
    private const double LeftInset = 7.2, TopInset = 3.6;
    private const int Levels = 9;
    private const double DefaultSize = 18;

    // The room and paragraphs of a shape's text, or null when the shape holds no text.
    private PptxBody? Body(XmlElement txBody, XmlElement? ph, Placeholder? layoutPh, Placeholder? masterPh, Scope scope, XmlElement? style)
    {
        var layers = new List<XmlElement?> { _defaultStyle };
        var box = new PptxBodyProps();
        if (ph is not null)
        {
            var styles = scope.Master.Root.Child(P, "txStyles");
            string group = GroupOf(ph.Attribute("type") ?? layoutPh?.Type);
            layers.Add(styles?.Child(P, group == "title" ? "titleStyle" : group == "body" ? "bodyStyle" : "otherStyle"));
            foreach (var template in new[] { masterPh, layoutPh })
            {
                var body = template?.Shape.Child(P, "txBody");
                layers.Add(body?.Child(DocxReader.A, "lstStyle"));
                box.Apply(body?.Child(DocxReader.A, "bodyPr"));
            }
        }
        layers.Add(txBody.Child(DocxReader.A, "lstStyle"));
        box.Apply(txBody.Child(DocxReader.A, "bodyPr"));

        int? fontColor = scope.Colors.First(style?.Child(DocxReader.A, "fontRef"));
        var paragraphs = Paragraphs(txBody, layers, scope.Colors, box, fontColor, out bool any);
        if (!any) return null;
        if (box.Rotated) Skip(PptxSkipped.TextRotation);
        return new PptxBody
        {
            Left = box.Left ?? LeftInset,
            Top = box.Top ?? TopInset,
            Right = box.Right ?? LeftInset,
            Bottom = box.Bottom ?? TopInset,
            Anchor = box.Anchor ?? LayoutVAlign.Top,
            Wrap = box.Wrap ?? true,
            Paragraphs = paragraphs,
        };
    }

    private static PptxLevelProps Level(List<XmlElement?> layers, int level, PptxColors colors)
    {
        var props = new PptxLevelProps();
        foreach (var layer in layers)
        {
            props.Apply(layer?.Child(DocxReader.A, "defPPr"), colors);
            props.Apply(layer?.Child(DocxReader.A, "lvl" + (level + 1).ToString(CultureInfo.InvariantCulture) + "pPr"), colors);
        }
        return props;
    }

    private List<LayoutParagraph> Paragraphs(XmlElement txBody, List<XmlElement?> layers, PptxColors colors, PptxBodyProps box, int? fontColor, out bool any)
    {
        var result = new List<LayoutParagraph>();
        var counters = new int[Levels];
        var schemes = new string?[Levels];
        int paragraphs = 0, chars = 0;
        bool cut = false;
        any = false;
        foreach (var p in txBody.Elements(DocxReader.A, "p"))
        {
            if (++paragraphs > _limits.MaxParagraphs)
            {
                cut = true;
                break;
            }
            _cancellation.ThrowIfCancellationRequested();
            var pPr = p.Child(DocxReader.A, "pPr");
            int level = (int)Math.Clamp(DocxReader.Number(pPr?.Attribute("lvl")) ?? 0, 0, Levels - 1);
            var props = Level(layers, level, colors);
            if (fontColor is { } color) props.Run.Color = color;
            props.Apply(pPr, colors);

            var runs = new List<LayoutRun>();
            foreach (var e in p.Elements())
            {
                if (e.Uri != DocxReader.A) continue;
                string? text = null;
                var rPr = e.Child(DocxReader.A, "rPr");
                var field = LayoutField.None;
                switch (e.Name)
                {
                    case "r": text = e.Child(DocxReader.A, "t")?.Text; break;
                    case "br": text = "\n"; break;
                    case "fld":
                        text = e.Child(DocxReader.A, "t")?.Text;
                        if (e.Attribute("type") == "slidenum") field = LayoutField.PageNumber;
                        break;
                }
                if (field == LayoutField.None && string.IsNullOrEmpty(text)) continue;
                text ??= "";
                if (chars + text.Length > _limits.MaxTextLength)
                {
                    cut = true;
                    int room = Math.Max(0, _limits.MaxTextLength - chars);
                    if (room > 0 && char.IsHighSurrogate(text[room - 1])) room--;
                    text = text[..room];
                }
                chars += text.Length;
                _totalText += text.Length;
                if (_totalText > _limits.MaxTotalText) throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation has too much text.");
                if (text.Length == 0 && field == LayoutField.None) continue;
                runs.AddRange(MakeRuns(props.Run, rPr, text, field, colors, box.FontScale));
            }

            bool hasText = runs.Count > 0;
            any |= hasText;
            if (!hasText) runs.Add(MakeRun(props.Run, p.Child(DocxReader.A, "endParaRPr"), "", LayoutField.None, colors, box.FontScale));

            string? label = hasText ? Bullet(props, level, counters, schemes) : null;
            if (hasText) Reset(counters, schemes, props.BulletKind == "auto" ? level + 1 : level);
            double? labelTab = null;
            if (label is not null)
            {
                runs.Insert(0, LabelRun(props, runs[0], label));
                if ((props.Indent ?? 0) < 0) labelTab = props.MarL ?? 0;
            }
            result.Add(MakeParagraph(props, runs, labelTab, box));
            if (cut) break;
        }
        if (cut) Skip(PptxSkipped.TextCut);
        return result;
    }

    private static void Reset(int[] counters, string?[] schemes, int from)
    {
        for (int i = from; i < counters.Length; i++)
        {
            counters[i] = 0;
            schemes[i] = null;
        }
    }

    // Hebrew and Arabic letters take the complex-script font; a field is never cut.
    private static IEnumerable<LayoutRun> MakeRuns(PptxRunProps inherited, XmlElement? rPr, string text, LayoutField field, PptxColors colors, double scale)
    {
        if (field != LayoutField.None || text.Length == 0)
        {
            yield return MakeRun(inherited, rPr, text, field, colors, scale);
            yield break;
        }
        foreach (var (part, complex) in ScriptRuns.Split(text)) yield return MakeRun(inherited, rPr, part, field, colors, scale, complex);
    }

    private static LayoutRun MakeRun(PptxRunProps inherited, XmlElement? rPr, string text, LayoutField field, PptxColors colors, double scale, bool complex = false)
    {
        var props = inherited.Copy();
        props.Apply(rPr, colors);
        double size = (props.Size ?? DefaultSize) * scale, shift = 0;
        if (props.Baseline is { } baseline and not 0)
        {
            shift = size * baseline / 100;
            size *= 2.0 / 3;
        }
        bool link = props.Link == true;
        return new LayoutRun
        {
            Text = props.Caps == true ? DocxReader.Upper(text) : text,
            Family = (complex ? props.CsFamily : null) ?? props.Family ?? colors.Theme.Font("minor") ?? "Calibri",
            Size = size,
            Bold = props.Bold == true,
            Italic = props.Italic == true,
            Underline = props.Underline == true || link,
            Strike = props.Strike == true,
            Color = (link ? colors.Hyperlink : null) ?? props.Color ?? 0,
            Highlight = props.Highlight,
            Shift = shift,
            Field = field,
            Rtl = props.Rtl == true,
        };
    }

    // The text of the bullet or number in front of a paragraph, or null for none. Numbers run on through paragraphs of one
    // level that use the same scheme; a paragraph without a number ends the run, and so does one on a higher level.
    private static string? Bullet(PptxLevelProps props, int level, int[] counters, string?[] schemes)
    {
        if (props.BulletKind == "char") return props.BulletChar is { } c ? Symbols(c, props.BulletFont) : null;
        if (props.BulletKind != "auto" || props.AutoType is not { } type) return null;
        counters[level] = schemes[level] == type && counters[level] > 0 ? counters[level] + 1 : props.AutoStart ?? 1;
        schemes[level] = type;
        return AutoNumber(type, counters[level]);
    }

    private static string Symbols(string text, string? font)
    {
        if (font is null || !(font.Equals("Wingdings", StringComparison.OrdinalIgnoreCase) || font.Equals("Symbol", StringComparison.OrdinalIgnoreCase)
            || font.StartsWith("Wingdings ", StringComparison.OrdinalIgnoreCase))) return text;
        return string.Concat(text.Select(ch => DocxNumbering.SymbolBullet(ch & 0xFF)));
    }

    private static string AutoNumber(string type, int value)
    {
        string format = type.StartsWith("roman", StringComparison.Ordinal) ? (type.Contains("Uc", StringComparison.Ordinal) ? "upperRoman" : "lowerRoman")
            : type.StartsWith("alpha", StringComparison.Ordinal) ? (type.Contains("Uc", StringComparison.Ordinal) ? "upperLetter" : "lowerLetter")
            : "decimal";
        string number = DocxNumbering.Format(value, format);
        if (type.EndsWith("ParenBoth", StringComparison.Ordinal)) return "(" + number + ")";
        if (type.EndsWith("ParenR", StringComparison.Ordinal)) return number + ")";
        if (type.EndsWith("Plain", StringComparison.Ordinal)) return number;
        return number + ".";
    }

    private static LayoutRun LabelRun(PptxLevelProps props, LayoutRun first, string label)
    {
        bool symbol = props.BulletKind == "char";
        double size = props.BulletPoints is { } points ? points : first.Size * (props.BulletPercent ?? 1);
        return new LayoutRun
        {
            Text = label + "\t",
            Family = props.BulletFont is { } font && symbol && !IsSymbolFont(font) ? font : first.Family,
            Size = size,
            Bold = !symbol && first.Bold,
            Italic = !symbol && first.Italic,
            Color = props.BulletColor ?? first.Color,
        };
    }

    private static bool IsSymbolFont(string font) =>
        font.Equals("Wingdings", StringComparison.OrdinalIgnoreCase) || font.Equals("Symbol", StringComparison.OrdinalIgnoreCase) || font.StartsWith("Wingdings ", StringComparison.OrdinalIgnoreCase);

    private static LayoutParagraph MakeParagraph(PptxLevelProps props, List<LayoutRun> runs, double? labelTab, PptxBodyProps box)
    {
        double size = runs.Max(r => r.Size);
        var rule = LineRule.Multiple;
        double spacing = 1;
        if (props.Line is { Points: true } exact)
        {
            rule = LineRule.Exact;
            spacing = Math.Max(1, exact.Value);
        }
        else spacing = Math.Max(0.1, (props.Line?.Value ?? 1) - box.LineReduction);
        return new LayoutParagraph
        {
            Runs = runs,
            Align = props.Align ?? (props.Rtl == true ? LayoutAlign.Right : LayoutAlign.Left),
            RightToLeft = props.Rtl == true,
            Left = props.MarL ?? 0,
            FirstLine = props.Indent ?? 0,
            Before = Space(props.Before, size),
            After = Space(props.After, size),
            LineSpacing = spacing,
            Rule = rule,
            LabelTab = labelTab,
        };
    }

    // A percentage is of the line, which is a little over the font size.
    private static double Space(PptxSpacing? spacing, double size) =>
        spacing is not { } s ? 0 : s.Points ? s.Value : s.Value * size * 1.2;
}
