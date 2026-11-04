namespace LazyPDF.Core;

/// <summary>What goes on a page in place of what was removed: the fill, and the overlay text.</summary>
internal static class RedactionOverlay
{
    private const double MinSize = 3;
    private const double MaxSize = 16;

    public static byte[] Build(IEnumerable<RedactionMark> marks, RedactionOptions options, PdfDrawFont? font, string fontName)
    {
        var w = new ContentWriter().Save();
        foreach (var mark in marks)
        {
            double[] fill = mark.Fill is { Length: 1 or 3 or 4 } ? mark.Fill : options.Fill is { Length: 1 or 3 or 4 } ? options.Fill : [0];
            Color(w, fill);
            foreach (var q in mark.Quads) w.Raw(RedactionScan.Polygons([Geometry.Corners(q)]) + "f");
            string? text = mark.OverlayText ?? options.OverlayText;
            if (font is null || string.IsNullOrEmpty(text)) continue;
            foreach (var q in mark.Quads) Text(w, q, text, options.RepeatOverlay, font, fontName, Dark(fill));
        }
        return w.Restore().ToArray();
    }

    private static void Color(ContentWriter w, double[] color)
    {
        switch (color.Length)
        {
            case 1: w.FillGray(color[0]); break;
            case 3: w.FillRgb(color[0], color[1], color[2]); break;
            default: w.FillCmyk(color[0], color[1], color[2], color[3]); break;
        }
    }

    private static bool Dark(double[] c) => c.Length switch
    {
        1 => c[0] < 0.5,
        3 => 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] < 0.5,
        _ => 1 - Math.Min(1, 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] + c[3]) < 0.5,
    };

    private static void Text(ContentWriter w, TextQuad q, string text, bool repeat, PdfDrawFont font, string fontName, bool onDark)
    {
        double width = Math.Sqrt(Math.Pow(q.X1 - q.X0, 2) + Math.Pow(q.Y1 - q.Y0, 2));
        double height = Math.Sqrt(Math.Pow(q.X3 - q.X0, 2) + Math.Pow(q.Y3 - q.Y0, 2));
        if (width < 1 || height < 1) return;
        double size = Math.Clamp(height * 0.6, 1, MaxSize);
        double natural = font.Width(text, size);
        if (natural > width * 0.98) size *= width * 0.98 / natural;
        if (size < MinSize) return;
        string line = text;
        if (repeat)
        {
            int times = (int)(width * 0.98 / font.Width(text + " ", size));
            if (times > 1) line = string.Join(' ', Enumerable.Repeat(text, times));
        }
        double drawn = font.Width(line, size);
        double ux = (q.X1 - q.X0) / width, uy = (q.Y1 - q.Y0) / width;
        double dx = (width - drawn) / 2, dy = height / 2 - size * (font.Ascent + font.Descent) / 2;
        w.BeginText().Font(fontName, size);
        if (onDark) w.FillGray(1);
        else w.FillGray(0);
        w.TextMatrix(new PdfMatrix(ux, uy, -uy, ux, q.X0 + dx * ux - dy * uy, q.Y0 + dx * uy + dy * ux)).Show(font.Encode(line)).EndText();
    }
}
