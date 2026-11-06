namespace LazyPDF.Core;

/// <param name="Threshold">How far a colour channel must differ, 0 to 255, to count.</param>
/// <param name="Tolerance">A pixel that matches one within this many pixels of its place is not a difference; this absorbs edges that fall differently on the grid.</param>
/// <param name="Align">Find the turn and shift of the old page first.</param>
/// <param name="MinPixels">Regions with fewer differing pixels are noise and dropped.</param>
public sealed record PixelOptions(int Threshold = 40, int Tolerance = 1, bool Align = true, int MinPixels = 4);

/// <param name="Region">In page points as displayed, origin top left.</param>
public sealed record PixelDifference(DisplayRect Region, int Pixels);

/// <param name="ShiftX">How far the old page had to move right, in pixels of the new one.</param>
/// <param name="ShiftY">Down.</param>
/// <param name="Degrees">How far it had to turn, clockwise on screen.</param>
public sealed record PixelAlignment(double ShiftX, double ShiftY, double Degrees);

/// <param name="Similarity">0 to 1: one minus the differing pixels over the pixels either page inks.</param>
/// <param name="Overlay">The new page faded, with ink only the new page has in green and ink only the old page has in red.</param>
public sealed record PixelComparison(IReadOnlyList<PixelDifference> Differences, double Similarity, PixelAlignment Alignment, PdfRgbaImage Overlay);

/// <summary>
/// Compares two rendered pages pixel by pixel. The old page is first brought onto the new one's grid
/// (resized if the sizes differ, turned and shifted by what a search over a shrunken copy finds, which is
/// what a re-scan needs), then a pixel differs when no pixel near its place on the other page is close in colour.
/// </summary>
public static class PixelComparer
{
    private const int MaxRegions = 5000;
    private const int InkLevel = 200;

    /// <summary>Renders both pages at <paramref name="dpi"/> and compares them; null when either cannot be drawn.</summary>
    public static PixelComparison? Compare(IPageRenderer before, int beforePage, IPageRenderer after, int afterPage, double dpi, PixelOptions? options = null) =>
        before.Render(beforePage, dpi) is { } a && after.Render(afterPage, dpi) is { } b ? Compare(a, b, dpi, options) : null;

    /// <param name="dpi">The resolution of <paramref name="after"/>, to put regions in points.</param>
    /// <exception cref="ArgumentException">An image is empty or its data is too short.</exception>
    public static PixelComparison Compare(PdfRgbaImage before, PdfRgbaImage after, double dpi, PixelOptions? options = null)
    {
        options ??= new PixelOptions();
        Check(before);
        Check(after);
        int w = after.Width, h = after.Height;
        var planes = Planes(after);
        var oldPlanes = Planes(before);
        var oldLuma = Luma(oldPlanes);
        var newLuma = Luma(planes);

        var warp = PixelWarp.None;
        if (options.Align)
        {
            var fitted = before.Width == w && before.Height == h ? oldLuma : PixelAligner.Resample(oldLuma, before.Width, before.Height, w, h, PixelWarp.None, 255);
            warp = PixelAligner.Estimate(fitted, newLuma, w, h);
        }
        bool same = warp == PixelWarp.None && before.Width == w && before.Height == h;
        var moved = same ? oldPlanes : [.. oldPlanes.Select(p => PixelAligner.Resample(p, before.Width, before.Height, w, h, warp, 255))];

        var mask = Differences(moved, planes, w, h, options);
        int grow = Math.Max(1, (int)Math.Round(dpi / 50));
        var regions = Regions(mask, w, h, grow, options.MinPixels, out var keep);

        var oldAligned = Luma(moved);
        int ink = 0, differing = 0;
        for (int i = 0; i < mask.Length; i++)
        {
            if (oldAligned[i] < InkLevel || newLuma[i] < InkLevel) ink++;
            if (keep[i]) differing++;
        }
        double similarity = ink == 0 ? (differing == 0 ? 1 : 0) : Math.Clamp(1 - (double)differing / ink, 0, 1);

        double toPoints = 72 / dpi;
        var differences = regions.Select(r => new PixelDifference(
            new DisplayRect(r.Left * toPoints, r.Top * toPoints, (r.Right - r.Left + 1) * toPoints, (r.Bottom - r.Top + 1) * toPoints), r.Pixels)).ToList();
        var alignment = new PixelAlignment(warp.ShiftX, warp.ShiftY, warp.Radians * 180 / Math.PI);
        return new PixelComparison(differences, similarity, alignment, Overlay(newLuma, oldAligned, keep, w, h));
    }

    private static void Check(PdfRgbaImage image)
    {
        if (image.Width <= 0 || image.Height <= 0 || image.Rgba.Length < (long)image.Width * image.Height * 4)
            throw new ArgumentException("The image is empty or its data is too short.");
    }

    private static byte[][] Planes(PdfRgbaImage image)
    {
        int n = image.Width * image.Height;
        var planes = new[] { new byte[n], new byte[n], new byte[n] };
        for (int i = 0; i < n; i++)
        {
            // Straight alpha over white, as the page is shown.
            int a = image.Rgba[i * 4 + 3];
            for (int c = 0; c < 3; c++) planes[c][i] = (byte)((image.Rgba[i * 4 + c] * a + 255 * (255 - a)) / 255);
        }
        return planes;
    }

    private static byte[] Luma(byte[][] planes)
    {
        var luma = new byte[planes[0].Length];
        for (int i = 0; i < luma.Length; i++) luma[i] = (byte)((planes[0][i] * 77 + planes[1][i] * 151 + planes[2][i] * 28) >> 8);
        return luma;
    }

    private static bool[] Differences(byte[][] a, byte[][] b, int w, int h, PixelOptions options)
    {
        var mask = new bool[w * h];
        var low = new byte[w * h];
        var high = new byte[w * h];
        for (int c = 0; c < 3; c++)
        {
            Extremes(b[c], w, h, options.Tolerance, low, high);
            Mark(a[c], low, high, options.Threshold, mask);
            Extremes(a[c], w, h, options.Tolerance, low, high);
            Mark(b[c], low, high, options.Threshold, mask);
        }
        return mask;
    }

    private static void Mark(byte[] value, byte[] low, byte[] high, int threshold, bool[] mask)
    {
        for (int i = 0; i < value.Length; i++)
        {
            if (low[i] - value[i] > threshold || value[i] - high[i] > threshold) mask[i] = true;
        }
    }

    /// <summary>The smallest and largest value in the (2r+1) square around each pixel, in two passes.</summary>
    private static void Extremes(byte[] source, int w, int h, int r, byte[] low, byte[] high)
    {
        // A reach past the page sees all of it; the clamp only keeps the sums below from overflowing.
        r = Math.Clamp(r, -(w + h), w + h);
        var rowLow = new byte[source.Length];
        var rowHigh = new byte[source.Length];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte lo = 255, hi = 0;
                for (int xx = Math.Max(0, x - r); xx <= Math.Min(w - 1, x + r); xx++)
                {
                    byte v = source[y * w + xx];
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
                rowLow[y * w + x] = lo;
                rowHigh[y * w + x] = hi;
            }
        }
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte lo = 255, hi = 0;
                for (int yy = Math.Max(0, y - r); yy <= Math.Min(h - 1, y + r); yy++)
                {
                    lo = Math.Min(lo, rowLow[yy * w + x]);
                    hi = Math.Max(hi, rowHigh[yy * w + x]);
                }
                low[y * w + x] = lo;
                high[y * w + x] = hi;
            }
        }
    }

    private readonly record struct Region(int Left, int Top, int Right, int Bottom, int Pixels);

    /// <summary>Differing pixels within 2 x grow of each other make one region. <paramref name="keep"/> marks the pixels of the regions that stay.</summary>
    private static List<Region> Regions(bool[] mask, int w, int h, int grow, int minPixels, out bool[] keep)
    {
        keep = new bool[mask.Length];
        var near = Dilate(mask, w, h, grow);
        var label = new int[mask.Length];
        var regions = new List<Region>();
        var stack = new Stack<int>();
        var members = new List<int>();
        int labels = 0;
        for (int start = 0; start < near.Length && regions.Count < MaxRegions; start++)
        {
            if (!near[start] || label[start] != 0) continue;
            int id = ++labels;
            int left = w, top = h, right = -1, bottom = -1, pixels = 0;
            members.Clear();
            label[start] = id;
            stack.Push(start);
            while (stack.Count > 0)
            {
                int p = stack.Pop();
                int x = p % w, y = p / w;
                if (mask[p])
                {
                    pixels++;
                    members.Add(p);
                    left = Math.Min(left, x);
                    right = Math.Max(right, x);
                    top = Math.Min(top, y);
                    bottom = Math.Max(bottom, y);
                }
                for (int ny = Math.Max(0, y - 1); ny <= Math.Min(h - 1, y + 1); ny++)
                {
                    for (int nx = Math.Max(0, x - 1); nx <= Math.Min(w - 1, x + 1); nx++)
                    {
                        int q = ny * w + nx;
                        if (!near[q] || label[q] != 0) continue;
                        label[q] = id;
                        stack.Push(q);
                    }
                }
            }
            if (pixels < minPixels) continue;
            regions.Add(new Region(left, top, right, bottom, pixels));
            foreach (int p in members) keep[p] = true;
        }
        return regions;
    }

    private static bool[] Dilate(bool[] mask, int w, int h, int r)
    {
        var across = new bool[mask.Length];
        for (int y = 0; y < h; y++)
        {
            int last = -1_000_000;
            for (int x = 0; x < w; x++)
            {
                if (mask[y * w + x]) last = x;
                if (x - last <= r) across[y * w + x] = true;
            }
            last = 1_000_000_000;
            for (int x = w - 1; x >= 0; x--)
            {
                if (mask[y * w + x]) last = x;
                if (last - x <= r) across[y * w + x] = true;
            }
        }
        var result = new bool[mask.Length];
        for (int x = 0; x < w; x++)
        {
            int last = -1_000_000;
            for (int y = 0; y < h; y++)
            {
                if (across[y * w + x]) last = y;
                if (y - last <= r) result[y * w + x] = true;
            }
            last = 1_000_000_000;
            for (int y = h - 1; y >= 0; y--)
            {
                if (across[y * w + x]) last = y;
                if (last - y <= r) result[y * w + x] = true;
            }
        }
        return result;
    }

    private static PdfRgbaImage Overlay(byte[] newLuma, byte[] oldLuma, bool[] keep, int w, int h)
    {
        var rgba = new byte[w * h * 4];
        for (int i = 0; i < newLuma.Length; i++)
        {
            byte faded = (byte)(255 - (255 - newLuma[i]) * 0.35);
            (byte r, byte g, byte b) = (faded, faded, faded);
            if (keep[i]) (r, g, b) = newLuma[i] < oldLuma[i] ? ((byte)0, (byte)170, (byte)0) : ((byte)220, (byte)0, (byte)0);
            rgba[i * 4] = r;
            rgba[i * 4 + 1] = g;
            rgba[i * 4 + 2] = b;
            rgba[i * 4 + 3] = 255;
        }
        return new PdfRgbaImage(w, h, rgba);
    }
}
