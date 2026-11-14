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

// Ported to C# from pdf.js (src/core/jbig2.js: decodeBitmap, decodeBitmapTemplate0, decodeRefinement) and
// changed: bitmaps are flat byte arrays, the template bits follow the order of T.88 whatever the adaptive
// pixels are, skipped pixels and typical prediction of refinement rows (TPGRON) are done, MMR goes through Ccitt.

namespace LazyPDF.Core;

/// <summary>The generic region (6.2) and generic refinement region (6.3) decoding procedures.</summary>
internal static class Jbig2Generic
{
    // 6.2.5.7, Figures 8 to 11: the context of the pseudo pixel that carries the typical prediction bit.
    private static readonly int[] ReusedContexts = [0x9b25, 0x0795, 0x00e5, 0x0195];

    // 6.3.5.6, Figures 14 and 15.
    private static readonly int[] RefinementReusedContexts = [0x0020, 0x0008];

    /// <summary>
    /// The pixels the template looks at, in the order of the context bits from the highest. The adaptive pixels
    /// (<paramref name="at"/>, x then y for each) sit where Figures 3 to 6 put them.
    /// </summary>
    private static void Template(int template, int[] at, out int[] x, out int[] y)
    {
        switch (template)
        {
            case 0:
                x = [at[6], -1, 0, 1, at[4], at[2], -2, -1, 0, 1, 2, at[0], -4, -3, -2, -1];
                y = [at[7], -2, -2, -2, at[5], at[3], -1, -1, -1, -1, -1, at[1], 0, 0, 0, 0];
                break;
            case 1:
                x = [-1, 0, 1, 2, -2, -1, 0, 1, 2, at[0], -3, -2, -1];
                y = [-2, -2, -2, -2, -1, -1, -1, -1, -1, at[1], 0, 0, 0];
                break;
            case 2:
                x = [-1, 0, 1, -2, -1, 0, 1, at[0], -2, -1];
                y = [-2, -2, -2, -1, -1, -1, -1, at[1], 0, 0];
                break;
            default:
                x = [-3, -2, -1, 0, 1, at[0], -4, -3, -2, -1];
                y = [-1, -1, -1, -1, -1, at[1], 0, 0, 0, 0];
                break;
        }
    }

    /// <summary>
    /// 6.2.5: an arithmetic coded generic region. <paramref name="skip"/> marks pixels that are not coded (halftone
    /// regions); <paramref name="at"/> has the x and y of every adaptive pixel (four of them for template 0).
    /// </summary>
    public static Jbig2Bitmap Decode(Jbig2Budget budget, Jbig2Arith arith, int width, int height, int template, bool typicalPrediction, Jbig2Bitmap? skip, int[] at)
    {
        var bitmap = new Jbig2Bitmap(width, height, budget);
        if (width == 0 || height == 0) return bitmap;
        var contexts = arith.Gb;
        if (template == 0 && skip is null && width >= 4 && at[0] == 3 && at[1] == -1 && at[2] == -3 && at[3] == -1 && at[4] == 2 && at[5] == -2 && at[6] == -2 && at[7] == -2)
        {
            DecodeTemplate0(arith, contexts, bitmap, typicalPrediction);
            return bitmap;
        }

        Template(template, at, out var tx, out var ty);
        int length = tx.Length;
        // A template pixel that is the next one's neighbour on the left keeps its place in the label of the following
        // pixel, shifted by one bit, so only the others are read again.
        int reuseMask = 0, minX = 0, maxX = 0, minY = 0, maxY = 0;
        var changing = new List<int>();
        for (int k = 0; k < length; k++)
        {
            minX = Math.Min(minX, tx[k]);
            maxX = Math.Max(maxX, tx[k]);
            minY = Math.Min(minY, ty[k]);
            maxY = Math.Max(maxY, ty[k]);
            if (k < length - 1 && ty[k] == ty[k + 1] && tx[k] == tx[k + 1] - 1) reuseMask |= 1 << (length - 1 - k);
            else changing.Add(k);
        }
        int changes = changing.Count;
        var changingX = new int[changes];
        var changingY = new int[changes];
        var changingBit = new int[changes];
        for (int c = 0; c < changes; c++)
        {
            int k = changing[c];
            changingX[c] = tx[k];
            changingY[c] = ty[k];
            changingBit[c] = 1 << (length - 1 - k);
        }
        // Inside this box every template pixel is inside the bitmap.
        int safeLeft = -minX, safeTop = -minY, safeRight = width - maxX, safeBottom = height - maxY;

        var px = bitmap.Pixels;
        int pseudoPixelContext = ReusedContexts[template];
        int ltp = 0;
        for (int i = 0; i < height; i++)
        {
            if (typicalPrediction)
            {
                ltp ^= arith.Bit(contexts, pseudoPixelContext);
                if (ltp != 0)
                {
                    if (i > 0) Array.Copy(px, (i - 1) * width, px, i * width, width);
                    continue;
                }
            }
            int label = 0;
            for (int j = 0; j < width; j++)
            {
                if (j >= safeLeft && j < safeRight && i >= safeTop && i < safeBottom)
                {
                    label = (label << 1) & reuseMask;
                    for (int c = 0; c < changes; c++)
                    {
                        if (px[(i + changingY[c]) * width + j + changingX[c]] != 0) label |= changingBit[c];
                    }
                }
                else
                {
                    label = 0;
                    for (int k = 0; k < length; k++)
                    {
                        int j0 = j + tx[k], i0 = i + ty[k];
                        if (j0 >= 0 && j0 < width && i0 >= 0 && i0 < height && px[i0 * width + j0] != 0) label |= 1 << (length - 1 - k);
                    }
                }
                if (skip is not null && skip.Pixels[i * width + j] != 0) continue;
                px[i * width + j] = (byte)arith.Bit(contexts, label);
            }
        }
        return bitmap;
    }

    // The common case, template 0 with its adaptive pixels where the standard has them: the label is updated, not rebuilt.
    private static void DecodeTemplate0(Jbig2Arith arith, byte[] contexts, Jbig2Bitmap bitmap, bool typicalPrediction)
    {
        int width = bitmap.Width, height = bitmap.Height;
        var px = bitmap.Pixels;
        var zero = new byte[width];
        int ltp = 0;
        for (int i = 0; i < height; i++)
        {
            int rowAt = i * width;
            if (typicalPrediction)
            {
                ltp ^= arith.Bit(contexts, ReusedContexts[0]);
                if (ltp != 0)
                {
                    if (i > 0) Array.Copy(px, rowAt - width, px, rowAt, width);
                    continue;
                }
            }
            var row1 = i >= 1 ? px : zero;
            var row2 = i >= 2 ? px : zero;
            int at1 = i >= 1 ? rowAt - width : 0;
            int at2 = i >= 2 ? rowAt - 2 * width : 0;
            int label = (row2[at2] << 13) | (row2[at2 + 1] << 12) | (row2[at2 + 2] << 11)
                | (row1[at1] << 7) | (row1[at1 + 1] << 6) | (row1[at1 + 2] << 5) | (row1[at1 + 3] << 4);
            for (int j = 0; j < width; j++)
            {
                int pixel = arith.Bit(contexts, label);
                px[rowAt + j] = (byte)pixel;
                label = ((label & 0x7bf7) << 1)
                    | (j + 3 < width ? row2[at2 + j + 3] << 11 : 0)
                    | (j + 4 < width ? row1[at1 + j + 4] << 4 : 0)
                    | pixel;
            }
        }
    }

    /// <summary>
    /// 6.2.6: an MMR coded generic region from <paramref name="start"/> to <paramref name="end"/>; <paramref name="used"/> is
    /// the number of bytes the coded rows took.
    /// </summary>
    public static Jbig2Bitmap Mmr(Jbig2Budget budget, byte[] data, int start, int end, int width, int height, out int used)
    {
        var bitmap = new Jbig2Bitmap(width, height, budget);
        used = 0;
        if (width == 0 || height == 0) return bitmap;
        if (start > end) throw PdfReadException.Damaged("A JBIG2 MMR region has no data.");
        var packed = Ccitt.DecodeMmr(data.AsSpan(start, end - start).ToArray(), width, height, out used);
        int stride = (width + 7) / 8;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++) bitmap.Pixels[y * width + x] = (byte)((packed[y * stride + (x >> 3)] >> (7 - (x & 7))) & 1);
        }
        return bitmap;
    }

    /// <summary>
    /// 6.3.5: a refinement of <paramref name="reference"/>, which sits at (<paramref name="offsetX"/>, <paramref name="offsetY"/>)
    /// of the new bitmap. <paramref name="at"/> has the two adaptive pixels of template 0 (the coding one first).
    /// </summary>
    public static Jbig2Bitmap Refine(Jbig2Budget budget, Jbig2Arith arith, int width, int height, int template, Jbig2Bitmap reference,
                                     int offsetX, int offsetY, bool typicalPrediction, int[] at)
    {
        var bitmap = new Jbig2Bitmap(width, height, budget);
        if (width == 0 || height == 0) return bitmap;
        int[] cx, cy, rx, ry;
        if (template == 0)
        {
            cx = [0, 1, -1, at[0]];
            cy = [-1, -1, 0, at[1]];
            rx = [0, 1, -1, 0, 1, -1, 0, 1, at[2]];
            ry = [-1, -1, 0, 0, 0, 1, 1, 1, at[3]];
        }
        else
        {
            cx = [-1, 0, 1, -1];
            cy = [-1, -1, -1, 0];
            rx = [0, -1, 0, 1, 0, 1];
            ry = [-1, 0, 0, 0, 1, 1];
        }
        var px = bitmap.Pixels;
        var contexts = arith.Gr;
        int pseudoPixelContext = RefinementReusedContexts[template];
        int ltp = 0;
        for (int i = 0; i < height; i++)
        {
            if (typicalPrediction) ltp ^= arith.Bit(contexts, pseudoPixelContext);
            for (int j = 0; j < width; j++)
            {
                // 6.3.5.6: where the 3 by 3 pixels of the reference around this one agree, so does the new pixel.
                if (ltp != 0)
                {
                    int center = Reference(reference, j - offsetX, i - offsetY);
                    bool same = true;
                    for (int dy = -1; dy <= 1 && same; dy++)
                    {
                        for (int dx = -1; dx <= 1; dx++)
                        {
                            if (Reference(reference, j - offsetX + dx, i - offsetY + dy) != center)
                            {
                                same = false;
                                break;
                            }
                        }
                    }
                    if (same)
                    {
                        px[i * width + j] = (byte)center;
                        continue;
                    }
                }
                int label = 0;
                for (int k = 0; k < cx.Length; k++)
                {
                    int i0 = i + cy[k], j0 = j + cx[k];
                    label <<= 1;
                    if (i0 >= 0 && i0 < height && j0 >= 0 && j0 < width) label |= px[i0 * width + j0];
                }
                for (int k = 0; k < rx.Length; k++)
                {
                    label = (label << 1) | Reference(reference, j + rx[k] - offsetX, i + ry[k] - offsetY);
                }
                px[i * width + j] = (byte)arith.Bit(contexts, label);
            }
        }
        return bitmap;
    }

    private static int Reference(Jbig2Bitmap reference, int x, int y) =>
        x < 0 || y < 0 || x >= reference.Width || y >= reference.Height ? 0 : reference.Pixels[y * reference.Width + x];
}
