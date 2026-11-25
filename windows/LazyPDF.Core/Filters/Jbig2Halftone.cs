/* Copyright 2012 Mozilla Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Ported to C# from pdf.js (src/core/jbig2.js: decodePatternDictionary, decodeHalftoneRegion) and changed: skipped
// cells, every combination operator, MMR planes read one after the other, and limits on patterns and the grid.

namespace LazyPDF.Core;

/// <summary>6.7 and 6.6: pattern dictionaries and the halftone regions that draw with them.</summary>
internal static class Jbig2Halftone
{
    /// <summary>The most patterns one dictionary may hold.</summary>
    public const int MaxPatterns = 1 << 16;

    /// <summary>The most cells a halftone grid may have.</summary>
    public const long MaxCells = 1 << 25;

    /// <summary>6.7.5: the collective bitmap of all patterns, cut up.</summary>
    public static List<Jbig2Bitmap> Patterns(Jbig2Budget budget, byte[] data, int start, int end, bool mmr, int template, int width, int height, long maxIndex)
    {
        if (width < 1 || height < 1) throw PdfReadException.Damaged("A JBIG2 pattern dictionary has a bad size.");
        if (maxIndex >= MaxPatterns) throw Jbig2Budget.TooBig();
        int count = (int)maxIndex + 1;
        budget.Keep((long)count * (width * height + 64));
        Jbig2Bitmap collective;
        if (mmr)
        {
            collective = Jbig2Generic.Mmr(budget, data, start, end, count * width, height, out _);
        }
        else
        {
            var arith = new Jbig2Arith(data, start, end, budget: budget);
            int[] at = template == 0 ? [-width, 0, -3, -1, 2, -2, -2, -2] : [-width, 0];
            collective = Jbig2Generic.Decode(budget, arith, count * width, height, template, false, null, at);
        }
        var patterns = new List<Jbig2Bitmap>(count);
        for (int i = 0; i < count; i++) patterns.Add(collective.Columns(i * width, width, budget));
        return patterns;
    }

    /// <summary>6.6.5: what a halftone region segment says (7.4.5.1).</summary>
    public sealed class Params
    {
        public bool Mmr;
        public int Template;
        public bool EnableSkip;
        public int CombinationOperator;
        public int DefaultPixel;
        public int Width;
        public int Height;
        public long GridWidth;
        public long GridHeight;
        public long GridX;
        public long GridY;
        public int VectorX;
        public int VectorY;
    }

    public static Jbig2Bitmap Region(Jbig2Budget budget, byte[] data, int start, int end, Params p, List<Jbig2Bitmap> patterns)
    {
        if (patterns.Count == 0) throw PdfReadException.Damaged("A JBIG2 halftone region has no patterns.");
        if (p.GridWidth * p.GridHeight > MaxCells || p.GridWidth > MaxCells || p.GridHeight > MaxCells) throw Jbig2Budget.TooBig();
        int gridWidth = (int)p.GridWidth, gridHeight = (int)p.GridHeight;
        var region = new Jbig2Bitmap(p.Width, p.Height, budget);
        if (p.DefaultPixel != 0) region.Fill(1);
        int patternWidth = patterns[0].Width, patternHeight = patterns[0].Height;
        budget.Work(Math.Max((long)gridWidth, 1) * Math.Max((long)gridHeight, 1));

        Jbig2Bitmap? skip = null;
        if (p.EnableSkip)
        {
            // 6.6.5.1: the cells whose pattern would fall outside the region are not coded.
            skip = new Jbig2Bitmap(gridWidth, gridHeight, budget);
            for (int m = 0; m < gridHeight; m++)
            {
                for (int n = 0; n < gridWidth; n++)
                {
                    long x = CellX(p, m, n), y = CellY(p, m, n);
                    if (x + patternWidth <= 0 || x >= p.Width || y + patternHeight <= 0 || y >= p.Height) skip.Pixels[m * gridWidth + n] = 1;
                }
            }
        }

        // Annex C: the gray values are coded as bit planes, the highest first, each the exclusive or of itself and the plane above.
        int planeCount = Jbig2Text.CodeLength(patterns.Count);
        var planes = new Jbig2Bitmap[planeCount];
        Jbig2Arith? arith = p.Mmr ? null : new Jbig2Arith(data, start, end, budget: budget);
        int[] at = p.Template == 0 ? [3, -1, -3, -1, 2, -2, -2, -2] : [p.Template == 1 ? 3 : 2, -1];
        int position = start;
        for (int j = planeCount - 1; j >= 0; j--)
        {
            Jbig2Bitmap plane;
            if (p.Mmr)
            {
                plane = Jbig2Generic.Mmr(budget, data, position, end, gridWidth, gridHeight, out int used);
                position += used;
            }
            else
            {
                plane = Jbig2Generic.Decode(budget, arith!, gridWidth, gridHeight, p.Template, false, skip, at);
            }
            if (j < planeCount - 1)
            {
                var above = planes[j + 1].Pixels;
                for (int i = 0; i < plane.Pixels.Length; i++) plane.Pixels[i] ^= above[i];
            }
            planes[j] = plane;
        }

        // 6.6.5.2: a pattern at each cell of the grid.
        for (int m = 0; m < gridHeight; m++)
        {
            for (int n = 0; n < gridWidth; n++)
            {
                int index = 0;
                for (int j = 0; j < planeCount; j++) index |= planes[j].Pixels[m * gridWidth + n] << j;
                var pattern = patterns[Math.Min(index, patterns.Count - 1)];
                long x = CellX(p, m, n), y = CellY(p, m, n);
                if (x + patternWidth <= 0 || x >= p.Width || y + patternHeight <= 0 || y >= p.Height) continue;
                budget.Work((long)patternWidth * patternHeight);
                region.Compose(pattern, (int)x, (int)y, p.CombinationOperator);
            }
        }
        return region;
    }

    private static long CellX(Params p, int m, int n) => (p.GridX + (long)m * p.VectorY + (long)n * p.VectorX) >> 8;

    private static long CellY(Params p, int m, int n) => (p.GridY + (long)m * p.VectorX - (long)n * p.VectorY) >> 8;
}
