namespace LazyPDF.Core;

/// <summary>
/// The turn and shift that bring an old picture onto a new one: the new picture is sampled at
/// <c>R(-angle) * (p - centre - shift) + centre</c>, scaled when the sizes differ.
/// </summary>
internal readonly record struct PixelWarp(double Radians, double ShiftX, double ShiftY)
{
    public static PixelWarp None => new(0, 0, 0);
}

/// <summary>
/// Finds the turn and shift between two pages on a shrunken copy. Each page is deskewed on its own
/// (the angle that makes its rows of ink sharpest), so the turn between them is the difference; the
/// old page is turned by that and the shift is read off the row and column profiles. A search at full
/// size then settles the last pixels.
/// </summary>
internal static class PixelAligner
{
    private const int SmallSide = 512;
    private const double MaxDegrees = 3;
    private const double Gain = 1.05;
    private const int RefineSamples = 100_000;
    private const int RefineReach = 3;

    /// <summary>The warp for two brightness grids of the same size.</summary>
    public static PixelWarp Estimate(byte[] oldLuma, byte[] newLuma, int width, int height)
    {
        int factor = Math.Max(1, (int)Math.Ceiling(Math.Max(width, height) / (double)SmallSide));
        var (smallOld, w, h) = Shrink(oldLuma, width, height, factor);
        var (smallNew, _, _) = Shrink(newLuma, width, height, factor);

        double degrees = Deskew(smallOld, w, h) - Deskew(smallNew, w, h);
        var turned = degrees == 0 ? smallOld : Resample(smallOld, w, h, w, h, new PixelWarp(degrees * Math.PI / 180, 0, 0), 0);
        var (_, shiftY) = Correlate(Profile(turned, w, h, rows: true), Profile(smallNew, w, h, rows: true));
        var (_, shiftX) = Correlate(Profile(turned, w, h, rows: false), Profile(smallNew, w, h, rows: false));
        var start = new PixelWarp(degrees * Math.PI / 180, Math.Round(shiftX * factor), Math.Round(shiftY * factor));
        return Refine(oldLuma, newLuma, width, height, start);
    }

    /// <summary>The turn, in degrees, that makes the rows of ink in the picture sharpest; 0 unless that is clearly better than leaving it.</summary>
    private static double Deskew(byte[] ink, int w, int h)
    {
        double Sharpness(double degrees)
        {
            var turned = degrees == 0 ? ink : Resample(ink, w, h, w, h, new PixelWarp(degrees * Math.PI / 180, 0, 0), 0);
            var rows = Profile(turned, w, h, rows: true);
            double sum = 0;
            for (int i = 1; i < rows.Length; i++) sum += (rows[i] - rows[i - 1]) * (rows[i] - rows[i - 1]);
            return sum;
        }
        double straight = Sharpness(0), bestScore = straight, best = 0;
        for (double degrees = -MaxDegrees; degrees <= MaxDegrees + 1e-9; degrees += 0.5)
        {
            double score = Sharpness(degrees);
            if (score > bestScore) (best, bestScore) = (degrees, score);
        }
        double centre = best;
        for (double degrees = centre - 0.5; degrees <= centre + 0.5 + 1e-9; degrees += 0.1)
        {
            double score = Sharpness(degrees);
            if (score > bestScore) (best, bestScore) = (degrees, score);
        }
        return bestScore > straight * Gain ? Math.Round(best, 3) : 0;
    }

    /// <summary>Box average of a grid, as ink: 255 where the page is black.</summary>
    private static (byte[] Ink, int Width, int Height) Shrink(byte[] luma, int width, int height, int factor)
    {
        int w = Math.Max(1, width / factor), h = Math.Max(1, height / factor);
        var ink = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int sum = 0, count = 0;
                for (int yy = y * factor; yy < Math.Min(height, (y + 1) * factor); yy++)
                {
                    for (int xx = x * factor; xx < Math.Min(width, (x + 1) * factor); xx++)
                    {
                        sum += luma[yy * width + xx];
                        count++;
                    }
                }
                ink[y * w + x] = (byte)(255 - sum / count);
            }
        }
        return (ink, w, h);
    }

    private static double[] Profile(byte[] ink, int w, int h, bool rows)
    {
        var profile = new double[rows ? h : w];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++) profile[rows ? y : x] += ink[y * w + x];
        }
        return profile;
    }

    /// <summary>
    /// The shift s that makes <c>old[i]</c> best match <c>updated[i + s]</c>, by normalised cross-correlation over
    /// a quarter of the length each way. The peak is read between the samples (a parabola through the three
    /// around it), so that a shift of half a pixel does not look like a worse match than a whole one.
    /// </summary>
    private static (double Score, double Shift) Correlate(double[] old, double[] updated)
    {
        int n = old.Length;
        double meanA = old.Average(), meanB = updated.Average();
        double normA = old.Sum(v => (v - meanA) * (v - meanA)), normB = updated.Sum(v => (v - meanB) * (v - meanB));
        if (normA < 1e-9 || normB < 1e-9) return (0, 0);
        double scale = 1 / Math.Sqrt(normA * normB);
        int reach = n / 4;
        var scores = new double[2 * reach + 1];
        int best = reach;
        for (int s = -reach; s <= reach; s++)
        {
            double sum = 0;
            for (int i = Math.Max(0, -s); i < Math.Min(n, n - s); i++) sum += (old[i] - meanA) * (updated[i + s] - meanB);
            scores[s + reach] = sum * scale;
            // Ties go to the smaller shift, so a blank margin does not pull a page sideways.
            if (scores[s + reach] > scores[best] + 1e-12 || (Math.Abs(scores[s + reach] - scores[best]) <= 1e-12 && Math.Abs(s) < Math.Abs(best - reach))) best = s + reach;
        }
        if (best == 0 || best == scores.Length - 1) return (scores[best], best - reach);
        double left = scores[best - 1], middle = scores[best], right = scores[best + 1];
        double curve = left - 2 * middle + right;
        if (curve >= -1e-12) return (middle, best - reach);
        double offset = 0.5 * (left - right) / curve;
        return (middle - 0.25 * (left - right) * offset, best - reach + offset);
    }

    /// <summary>
    /// Looks around the estimate at full size: shifts up to <see cref="RefineReach"/> pixels and a few hundredths
    /// of a degree either way, keeping the one with the least brightness difference over a sample of the page.
    /// </summary>
    private static PixelWarp Refine(byte[] oldLuma, byte[] newLuma, int width, int height, PixelWarp start)
    {
        int stride = Math.Max(1, (int)Math.Sqrt((double)width * height / RefineSamples));
        var best = start;
        long bestCost = Cost(oldLuma, newLuma, width, height, start, stride, long.MaxValue);
        foreach (double turn in new[] { 0, -0.05, 0.05, -0.1, 0.1 })
        {
            for (int dy = -RefineReach; dy <= RefineReach; dy++)
            {
                for (int dx = -RefineReach; dx <= RefineReach; dx++)
                {
                    var warp = new PixelWarp(start.Radians + turn * Math.PI / 180, start.ShiftX + dx, start.ShiftY + dy);
                    long cost = Cost(oldLuma, newLuma, width, height, warp, stride, bestCost);
                    if (cost < bestCost)
                    {
                        bestCost = cost;
                        best = warp;
                    }
                }
            }
        }
        return best;
    }

    private static long Cost(byte[] oldLuma, byte[] newLuma, int w, int h, PixelWarp warp, int stride, long limit)
    {
        var map = new Mapping(w, h, w, h, warp);
        long cost = 0;
        for (int y = 0; y < h; y += stride)
        {
            for (int x = 0; x < w; x += stride)
            {
                var (sx, sy) = map.Source(x, y);
                int ix = (int)Math.Round(sx), iy = (int)Math.Round(sy);
                int value = ix < 0 || iy < 0 || ix >= w || iy >= h ? 255 : oldLuma[iy * w + ix];
                cost += Math.Abs(value - newLuma[y * w + x]);
            }
            if (cost >= limit) return cost;
        }
        return cost;
    }

    /// <summary>Samples <paramref name="source"/> onto a grid of the new page's size, bilinear, with <paramref name="fill"/> outside it.</summary>
    public static byte[] Resample(byte[] source, int sourceWidth, int sourceHeight, int width, int height, PixelWarp warp, byte fill)
    {
        var result = new byte[width * height];
        var map = new Mapping(width, height, sourceWidth, sourceHeight, warp);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var (sx, sy) = map.Source(x, y);
                if (sx < -0.5 || sy < -0.5 || sx > sourceWidth - 0.5 || sy > sourceHeight - 0.5)
                {
                    result[y * width + x] = fill;
                    continue;
                }
                int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                double fx = sx - x0, fy = sy - y0;
                int x1 = Math.Min(sourceWidth - 1, x0 + 1), y1 = Math.Min(sourceHeight - 1, y0 + 1);
                x0 = Math.Max(0, x0);
                y0 = Math.Max(0, y0);
                double top = source[y0 * sourceWidth + x0] * (1 - fx) + source[y0 * sourceWidth + x1] * fx;
                double bottom = source[y1 * sourceWidth + x0] * (1 - fx) + source[y1 * sourceWidth + x1] * fx;
                result[y * width + x] = (byte)Math.Round(top * (1 - fy) + bottom * fy);
            }
        }
        return result;
    }

    private readonly struct Mapping
    {
        private readonly double _cos, _sin, _cx, _cy, _shiftX, _shiftY, _scaleX, _scaleY;

        public Mapping(int width, int height, int sourceWidth, int sourceHeight, PixelWarp warp)
        {
            _cos = Math.Cos(warp.Radians);
            _sin = Math.Sin(warp.Radians);
            _cx = (width - 1) / 2.0;
            _cy = (height - 1) / 2.0;
            (_shiftX, _shiftY) = (warp.ShiftX, warp.ShiftY);
            (_scaleX, _scaleY) = ((double)sourceWidth / width, (double)sourceHeight / height);
        }

        public (double X, double Y) Source(int x, int y)
        {
            double px = x - _cx - _shiftX, py = y - _cy - _shiftY;
            double ux = _cos * px + _sin * py + _cx, uy = -_sin * px + _cos * py + _cy;
            return ((ux + 0.5) * _scaleX - 0.5, (uy + 0.5) * _scaleY - 0.5);
        }
    }
}
