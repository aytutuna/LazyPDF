namespace LazyPDF.Core;

internal sealed partial class AppearanceBuilder
{
    private const double TextPadding = 2;

    private AppearanceCanvas FreeText(PdfAnnotation a)
    {
        var c = Canvas(a);
        var format = FreeTextFormat(a);
        var rd = a.RectDifference;
        var box = rd.Count == 4 ? new PdfRect(a.Rect.Left + rd[0], a.Rect.Bottom + rd[1], a.Rect.Right - rd[2], a.Rect.Top - rd[3]) : a.Rect;
        if (box.IsEmpty) box = a.Rect;
        double width = a.Border.Width;
        c.Transparency(a.Opacity, multiply: false);

        if (Paints(a.InteriorColor) && c.Color(a.InteriorColor, stroke: false))
        {
            c.W.Rect(c.X(box.Left), c.Y(box.Bottom), box.Width, box.Height).Fill();
        }
        bool border = width > 0 && Paints(a.Color) && c.Color(a.Color, stroke: true);
        if (border)
        {
            c.Stroke(width, a.Border.Style == BorderStyle.Dashed ? a.Border.Dash : null);
            c.W.Rect(c.X(box.Left) + width / 2, c.Y(box.Bottom) + width / 2, box.Width - width, box.Height - width).Stroke();
        }
        if (a.Callout.Count >= 4) Callout(c, a, border);

        var paragraphs = Paragraphs(a, format);
        double inset = TextPadding + (border ? width : 0);
        var textBox = new PdfRect(box.Left + inset, box.Bottom + inset, box.Right - inset, box.Top - inset);
        if (textBox.IsEmpty || paragraphs.Count == 0) return c;

        var runs = paragraphs.SelectMany(p => p).ToList();
        var cache = new Dictionary<(string, FontStyles), PdfDrawFont>();
        var names = new Dictionary<int, string>();
        // A font only has to cover the runs that are set in it.
        var lines = TextLayout.Layout(paragraphs, textBox.Width, format,
            f => FontFor(f, [.. runs.Where(r => r.Format.Family == f.Family && r.Format.Style == f.Style).Select(r => r.Text)], cache));

        c.W.Save();
        c.W.Rect(c.X(box.Left), c.Y(box.Bottom), box.Width, box.Height).Clip();
        double y = textBox.Top;
        foreach (var line in lines)
        {
            if (y < box.Bottom) break;
            double baseline = y - line.Ascent;
            double x = a.Alignment switch
            {
                1 => textBox.Left + (textBox.Width - line.Width) / 2,
                2 => textBox.Right - line.Width,
                _ => textBox.Left,
            };
            foreach (var piece in line.Pieces)
            {
                DrawPiece(c, piece, x, baseline, names);
                x += piece.Width;
            }
            y -= line.Height;
        }
        c.W.Restore();
        return c;
    }

    private void DrawPiece(AppearanceCanvas c, Piece piece, double x, double baseline, Dictionary<int, string> names)
    {
        if (piece.Text.Length == 0) return;
        var format = piece.Run.Format;
        if (!names.TryGetValue(piece.Font.Reference.Number, out string? name))
        {
            name = c.AddFont(piece.Font.Reference);
            names[piece.Font.Reference.Number] = name;
        }
        c.Color(format.Color, stroke: false);
        c.W.BeginText().Font(name, format.Size).MoveText(c.X(x), c.Y(baseline)).Show(piece.Font.Encode(piece.Text)).EndText();
        if (format.Underline)
        {
            c.Color(format.Color, stroke: true);
            c.W.LineWidth(Math.Max(0.5, format.Size / 18));
            c.Move(x, baseline - format.Size * 0.12).Line(x + piece.Width, baseline - format.Size * 0.12);
            c.W.Stroke();
        }
    }

    private static void Callout(AppearanceCanvas c, PdfAnnotation a, bool hasColor)
    {
        var points = Points(a.Callout);
        if (points.Count < 2) return;
        if (!hasColor) c.Color(Black, stroke: true);
        double width = a.Border.Width > 0 ? a.Border.Width : 1;
        c.Stroke(width, null);
        c.Polyline(points, close: false);
        c.W.Stroke();
        var line = a with { Border = a.Border with { Width = width }, Color = hasColor ? a.Color : Black };
        DrawEnding(c, line, a.StartEnding, points[0], Unit(points[0].X - points[1].X, points[0].Y - points[1].Y));
    }

    private static TextFormat FreeTextFormat(PdfAnnotation a)
    {
        var f = TextFormat.Default;
        var (font, size, color) = DefaultAppearance.Parse(a.DefaultAppearance);
        if (font is not null) f = DefaultAppearance.FormatOf(font, f);
        if (size is > 0) f = f with { Size = size.Value };
        if (color is not null) f = f with { Color = color };
        return f.WithCss(a.DefaultStyle);
    }

    private static List<List<TextRun>> Paragraphs(PdfAnnotation a, TextFormat format)
    {
        if (a.RichText is { Length: > 0 } rich && PdfRichText.Parse(rich, format) is { } parsed && parsed.Any(p => p.Count > 0)) return parsed;
        string text = a.Contents ?? "";
        if (text.Length == 0) return [];
        return [.. text.ReplaceLineEndings("\n").Split('\n').Select(line => line.Length == 0 ? [] : new List<TextRun> { new(line, format) })];
    }

    private PdfDrawFont FontFor(TextFormat format, List<string> texts, Dictionary<(string, FontStyles), PdfDrawFont> cache)
    {
        if (cache.TryGetValue((format.Family, format.Style), out var known)) return known;
        var font = Embedder.AddCovering(format.Family, format.Style, texts) ?? Embedder.Add("Helvetica", format.Style, texts)
            ?? throw new InvalidOperationException(AnnotationText.NoFont);
        _undrawn.UnionWith(font.Missing);
        cache[(format.Family, format.Style)] = font;
        return font;
    }

    private AppearanceCanvas Stamp(PdfAnnotation a)
    {
        var c = Canvas(a);
        string name = a.IconName ?? "Draft";
        string label = AnnotationText.StampLabel(name);
        var color = a.Color ?? StampColor(name);
        c.Transparency(a.Opacity, multiply: false);
        double w = a.Rect.Width, h = a.Rect.Height;
        double line = Math.Clamp(Math.Min(w, h) / 14, 1, 4);
        if (c.Color(color, stroke: true))
        {
            c.Stroke(line, null);
            double radius = Math.Min(h / 6, 6);
            RoundedRect(c, line / 2, line / 2, w - line / 2, h - line / 2, radius);
            c.W.Stroke();
        }
        var bold = new TextFormat("Helvetica", 12, true, false, false, [.. color ?? Black]);
        var font = FontFor(bold, [label], []);
        double pad = line * 2;
        double size = Math.Min(h * 0.5, (w - 2 * pad) / Math.Max(0.001, font.Width(label, 1)));
        if (size < 1) return c;
        double textWidth = font.Width(label, size);
        double baseline = (h - (font.Ascent + font.Descent) * size) / 2;
        string fontName = c.AddFont(font.Reference);
        c.Color(color, stroke: false);
        c.W.BeginText().Font(fontName, size).MoveText((w - textWidth) / 2, baseline).Show(font.Encode(label)).EndText();
        return c;
    }

    private static double[] StampColor(string name) => name switch
    {
        "Approved" or "Final" or "ForPublicRelease" => [0, 0.5, 0.15],
        "AsIs" or "Experimental" or "Sold" or "Departmental" or "ForComment" => [0, 0.2, 0.7],
        _ => [0.75, 0, 0],
    };

    private static void RoundedRect(AppearanceCanvas c, double l, double b, double r, double t, double radius)
    {
        const double K = 0.5522847498;
        double k = radius * K;
        c.W.MoveTo(l + radius, b).LineTo(r - radius, b).CurveTo(r - radius + k, b, r, b + radius - k, r, b + radius)
            .LineTo(r, t - radius).CurveTo(r, t - radius + k, r - radius + k, t, r - radius, t)
            .LineTo(l + radius, t).CurveTo(l + radius - k, t, l, t - radius + k, l, t - radius)
            .LineTo(l, b + radius).CurveTo(l, b + radius - k, l + radius - k, b, l + radius, b).Close();
    }
}
