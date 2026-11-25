namespace LazyPDF.Core;

/// <summary>What one JBIG2 decode may allocate, so that a hostile stream cannot make the decoder run out of memory.</summary>
internal sealed class Jbig2Budget
{
    /// <summary>The pixels of every bitmap made during one decode, whether still alive or not.</summary>
    private long _total = 3 * PdfImageSamples.MaxPixels;

    /// <summary>The globals of an image may be shared by many; they make symbols and tables, not pages.</summary>
    public void ForGlobals()
    {
        _total = Math.Min(_total, 1L << 26);
        _work = Math.Min(_work, 1L << 27);
    }

    /// <summary>The budget of the image's own segments: the most there is, or tied to the size of its picture.</summary>
    public void ForImage(long fitPixels)
    {
        _total = 3 * PdfImageSamples.MaxPixels;
        _work = 1L << 29;
        if (fitPixels > 0) Fit(fitPixels);
    }

    /// <summary>
    /// With the pixels of the picture the page is fitted to, what a decode may make is a multiple of that and a little more:
    /// a dictionary that says 1 by 1 does not get a page of millions of pixels made for it and cut down.
    /// </summary>
    public void Fit(long fitPixels)
    {
        // Past this the other limits are the smaller ones; the cap keeps the products below from overflowing.
        fitPixels = Math.Min(fitPixels, 1L << 40);
        _total = Math.Min(_total, 16 * fitPixels + (1 << 24));
        // Enough for a page of symbols however small, and for drawing over the picture many times.
        _work = Math.Min(_work, 32 * fitPixels + (1 << 26));
    }

    /// <summary>The pixels of the symbols and patterns that stay around for later segments.</summary>
    private long _kept = 1L << 26;

    /// <summary>The pixels that symbols and refinements may be drawn or coded over, all together.</summary>
    private long _work = 1L << 29;

    public static PdfReadException TooBig() => FilterBuffer.TooBig();

    /// <summary>The arrays a segment makes whatever it holds, counted as pixels.</summary>
    public void Fixed(long bytes) => Charge(bytes, 1);

    public void Charge(long width, long height)
    {
        if (width < 0 || height < 0) throw TooBig();
        // A bitmap with no columns or no rows still costs the rows or columns that a loop over it walks.
        long pixels = Math.Max(width, 1) * Math.Max(height, 1);
        if (pixels > PdfImageSamples.MaxPixels || pixels > _total) throw TooBig();
        _total -= pixels;
    }

    public void Work(long pixels)
    {
        if (pixels > _work) throw TooBig();
        _work -= pixels;
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
        int left = (int)Math.Min(source.Width, Math.Max(0L, -(long)x)), top = (int)Math.Min(source.Height, Math.Max(0L, -(long)y));
        int right = (int)Math.Min(source.Width, (long)Width - x), bottom = (int)Math.Min(source.Height, (long)Height - y);
        if (left >= right || top >= bottom) return;
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
