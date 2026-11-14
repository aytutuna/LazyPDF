namespace LazyPDF.Core;

/// <summary>What one JBIG2 decode may allocate, so that a hostile stream cannot make the decoder run out of memory.</summary>
internal sealed class Jbig2Budget
{
    /// <summary>The pixels of every bitmap made during one decode, whether still alive or not.</summary>
    private long _total = 3 * PdfImageSamples.MaxPixels;

    /// <summary>The pixels of the symbols and patterns that stay around for later segments.</summary>
    private long _kept = 1L << 26;

    public static PdfReadException TooBig() => new(PdfReadProblem.Unsupported, "A JBIG2 image needs too much memory.");

    public void Charge(long width, long height)
    {
        long pixels = width * height;
        if (width < 0 || height < 0 || pixels > PdfImageSamples.MaxPixels || pixels > _total) throw TooBig();
        _total -= pixels;
    }

    public void Keep(long pixels)
    {
        if (pixels > _kept) throw TooBig();
        _kept -= pixels;
    }
}

/// <summary>A bilevel image as one byte, 0 or 1, per pixel; 1 is black. Rows follow each other without padding.</summary>
internal sealed class Jbig2Bitmap
{
    public readonly int Width;
    public readonly int Height;
    public readonly byte[] Pixels;

    public Jbig2Bitmap(int width, int height, Jbig2Budget budget)
    {
        budget.Charge(width, height);
        Width = width;
        Height = height;
        Pixels = new byte[width * height];
    }

    public void Fill(byte value) => Array.Fill(Pixels, value);

    /// <summary>
    /// Combines <paramref name="source"/> with this bitmap with its top left corner at (x, y), the parts outside this bitmap
    /// dropped. The operators are those of 7.4.1.5: 0 OR, 1 AND, 2 XOR, 3 XNOR, 4 REPLACE.
    /// </summary>
    public void Compose(Jbig2Bitmap source, int x, int y, int op)
    {
        int left = Math.Max(0, -x), top = Math.Max(0, -y);
        int right = (int)Math.Min(source.Width, (long)Width - x), bottom = (int)Math.Min(source.Height, (long)Height - y);
        for (int sy = top; sy < bottom; sy++)
        {
            int from = sy * source.Width;
            int to = (y + sy) * Width + x;
            for (int sx = left; sx < right; sx++)
            {
                int s = source.Pixels[from + sx];
                int d = Pixels[to + sx];
                Pixels[to + sx] = (byte)(op switch
                {
                    0 => d | s,
                    1 => d & s,
                    2 => d ^ s,
                    3 => 1 ^ d ^ s,
                    _ => s,
                });
            }
        }
    }

    /// <summary>The columns from <paramref name="x"/> to <paramref name="x"/> + <paramref name="width"/> of every row.</summary>
    public Jbig2Bitmap Columns(int x, int width, Jbig2Budget budget)
    {
        var part = new Jbig2Bitmap(width, Height, budget);
        for (int row = 0; row < Height; row++) Array.Copy(Pixels, row * Width + x, part.Pixels, row * width, width);
        return part;
    }
}
