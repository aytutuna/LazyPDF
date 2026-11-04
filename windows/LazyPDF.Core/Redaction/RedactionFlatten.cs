namespace LazyPDF.Core;

/// <summary>
/// Turns a page into a picture of itself with the marks filled in the pixels. It is what is left for a page the redaction
/// cannot follow to its end: the page is drawn from the file as it stands, so nothing is read from content that was
/// not understood, and the picture holds only what a viewer shows.
/// </summary>
internal static class RedactionFlatten
{
    private const double MaxDpi = 1200;
    private static readonly string[] Kept = ["Type", "Parent", "MediaBox", "CropBox", "Rotate", "UserUnit"];

    /// <summary>The page's own entries after this are the boxes and the turn, one content stream that places the picture, and resources that name it and the overlay font.</summary>
    public static void Page(PdfDocument work, PdfPage page, IReadOnlyList<RedactionMark> marks, RedactionOptions options, PdfDrawFont? font)
    {
        double dpi = options.FlattenDpi;
        if (!(dpi > 0 && dpi <= MaxDpi)) throw new ArgumentOutOfRangeException(nameof(options));
        if (options.Renderer?.Render(page.Index, dpi) is not { } drawn || drawn.Width < 1 || drawn.Height < 1
            || (long)drawn.Width * drawn.Height > PdfImageSamples.MaxPixels || drawn.Rgba.Length != (long)drawn.Width * drawn.Height * 4)
        {
            throw new InvalidOperationException(RedactionText.NotDrawn(page.Index));
        }
        var geometry = new PageGeometry(page);
        double sx = drawn.Width / geometry.Width, sy = drawn.Height / geometry.Height;
        // The picture is stretched to the page, so one that was drawn with another shape would put the marks in the wrong place.
        if (Math.Abs(sx - sy) > 1 / geometry.Width + 1 / geometry.Height) throw new InvalidOperationException(RedactionText.NotDrawn(page.Index));
        var pixels = OnWhite(drawn.Rgba);
        foreach (var mark in marks)
        {
            byte[] color = Rgb(RedactionOverlay.FillOf(mark, options));
            foreach (var q in mark.Quads)
            {
                // The corners as the area orders them: the quad can come in any order, and a crossing polygon fills two triangles only.
                var corners = MarkArea.Of(q).Points
                    .Select(c => geometry.ToDisplay(c.X, c.Y)).Select(d => (X: d.X * sx, Y: d.Y * sy)).ToArray();
                Fill(pixels, drawn.Width, drawn.Height, corners, color);
            }
        }
        var image = PdfImageWriter.AddRgba(work, drawn.Width, drawn.Height, pixels);

        // The picture is the displayed page: its top left is the display origin, so the unit square maps through the inverse of the display.
        var (ox, oy) = geometry.ToUser(0, geometry.Height);
        var (ux, uy) = geometry.ToUser(geometry.Width, geometry.Height);
        var (vx, vy) = geometry.ToUser(0, 0);
        var resources = new PdfDictionary();
        string name = ContentResources.Add(work, resources, "XObject", image.Reference, "RdPage");
        var content = new ContentWriter().Paint(name, new PdfMatrix(ux - ox, uy - oy, vx - ox, vy - oy, ox, oy));
        string fontName = font is not null && marks.Any(m => !string.IsNullOrEmpty(m.OverlayText ?? options.OverlayText))
            ? ContentResources.Add(work, resources, "Font", font.Reference, "RdF")
            : "";
        var overlay = RedactionOverlay.Build(marks, options, font, fontName);
        foreach (var (key, _) in page.Dictionary.Entries.ToList())
        {
            if (!Kept.Contains(key)) page.Dictionary.Remove(key);
        }
        page.Dictionary["Resources"] = resources;
        page.Dictionary["Contents"] = PdfRedactor.Store(work, [.. content.ToArray(), (byte)'\n', .. overlay]);
    }

    // What shows through is white paper, so no soft mask comes along.
    private static byte[] OnWhite(byte[] rgba)
    {
        var pixels = (byte[])rgba.Clone();
        for (int i = 0; i + 3 < pixels.Length; i += 4)
        {
            int alpha = pixels[i + 3];
            for (int c = 0; c < 3 && alpha != 255; c++) pixels[i + c] = (byte)((pixels[i + c] * alpha + 255 * (255 - alpha) + 127) / 255);
            pixels[i + 3] = 255;
        }
        return pixels;
    }

    private static byte[] Rgb(double[] color)
    {
        double[] rgb = color.Length switch
        {
            1 => [color[0], color[0], color[0]],
            3 => color,
            _ => [.. color[..3].Select(c => 1 - Math.Min(1, c + color[3]))],
        };
        return [.. rgb.Select(c => (byte)Math.Round(Math.Clamp(c, 0, 1) * 255))];
    }

    // A pixel the polygon touches is filled, so the edge of a mark never leaves a row of the picture behind.
    private static void Fill(byte[] pixels, int width, int height, (double X, double Y)[] polygon, byte[] color)
    {
        int left = Pixel(Math.Floor(polygon.Min(p => p.X)) - 1, width), right = Pixel(Math.Ceiling(polygon.Max(p => p.X)) + 1, width);
        int top = Pixel(Math.Floor(polygon.Min(p => p.Y)) - 1, height), bottom = Pixel(Math.Ceiling(polygon.Max(p => p.Y)) + 1, height);
        for (int y = top; y <= bottom; y++)
        {
            for (int x = left; x <= right; x++)
            {
                if (!Touches(polygon, x + 0.5, y + 0.5)) continue;
                int i = (y * width + x) * 4;
                pixels[i] = color[0];
                pixels[i + 1] = color[1];
                pixels[i + 2] = color[2];
            }
        }
    }

    // Clamped before the cast: a mark far outside the page must still fill what it reaches.
    private static int Pixel(double at, int size) => (int)Math.Clamp(at, 0, size - 1);

    private static bool Touches((double X, double Y)[] polygon, double x, double y)
    {
        bool inside = false;
        for (int i = 0, j = polygon.Length - 1; i < polygon.Length; j = i++)
        {
            var (a, b) = (polygon[i], polygon[j]);
            if ((a.Y > y) != (b.Y > y) && x < (b.X - a.X) * (y - a.Y) / (b.Y - a.Y) + a.X) inside = !inside;
            double dx = b.X - a.X, dy = b.Y - a.Y, length = dx * dx + dy * dy;
            double t = length == 0 ? 0 : Math.Clamp(((x - a.X) * dx + (y - a.Y) * dy) / length, 0, 1);
            if (Math.Pow(a.X + t * dx - x, 2) + Math.Pow(a.Y + t * dy - y, 2) <= 1) return true;
        }
        return inside;
    }
}
