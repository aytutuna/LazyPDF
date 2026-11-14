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

// Ported to C# from pdf.js (src/core/jbig2.js: decodeSymbolDictionary) and changed: Huffman coding with
// refinement and aggregation, retained contexts, and limits on the number of symbols.

namespace LazyPDF.Core;

/// <summary>What the symbol dictionary decoding procedure (6.5, Table 13) is given.</summary>
internal sealed class Jbig2SymbolParams
{
    public bool Huffman;
    public bool Refine;
    public int Template;
    public int RefinementTemplate;
    public int[] At = [];
    public int[] RefinementAt = [-1, -1, -1, -1];
    public int ExportedCount;
    public int NewCount;
    public List<Jbig2Bitmap> Input = [];
    public Jbig2Huffman? DeltaHeight;
    public Jbig2Huffman? DeltaWidth;
    public Jbig2Huffman? BitmapSize;
    public Jbig2Huffman? AggregateInstances;

    /// <summary>The refinement contexts of a Huffman coded dictionary, whose refinements each have an arithmetic decoder of their own.</summary>
    public byte[] RefineContexts = new byte[1 << 13];
}

/// <summary>The symbols a dictionary exports, and the contexts it leaves for a later one to continue from (7.4.2.2).</summary>
internal sealed class Jbig2SymbolDictionary(List<Jbig2Bitmap> exported, byte[]? gb, byte[]? gr)
{
    public List<Jbig2Bitmap> Exported { get; } = exported;
    public byte[]? Gb { get; } = gb;
    public byte[]? Gr { get; } = gr;
}

/// <summary>6.5: decodes the new symbols of a dictionary and picks the exported ones.</summary>
internal static class Jbig2Symbols
{
    /// <summary>The most symbols one dictionary and what it refers to may hold.</summary>
    public const int MaxSymbols = 1 << 20;

    public static List<Jbig2Bitmap> Decode(Jbig2Budget budget, Jbig2Arith? arith, Jbig2Reader? reader, Jbig2SymbolParams p)
    {
        if (p.NewCount < 0 || p.ExportedCount < 0 || (long)p.Input.Count + p.NewCount > MaxSymbols)
            throw PdfReadException.Damaged("A JBIG2 symbol dictionary has too many symbols.");
        bool huffman = p.Huffman;
        int total = p.Input.Count + p.NewCount;
        int codeLength = Jbig2Text.CodeLength(total);
        // 6.5.8.2.3
        if (huffman) codeLength = Math.Max(codeLength, 1);

        // The input symbols first, then the new ones as they are decoded; aggregate symbols may use both.
        var all = new List<Jbig2Bitmap>(p.Input);
        var widths = new List<int>();
        int height = 0;
        int classes = 0;
        while (all.Count < total)
        {
            // Every height class holds a symbol; a stream with empty ones is one that is cut off.
            if (++classes > 2 * p.NewCount + 16) throw PdfReadException.Damaged("A JBIG2 symbol dictionary has empty height classes.");
            long nextHeight = (long)height + Delta(huffman, p.DeltaHeight, arith, reader, Jbig2Arith.Iadh);
            if (nextHeight < 0 || nextHeight > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 symbol has a bad height.");
            height = (int)nextHeight;
            long width = 0, totalWidth = 0;
            widths.Clear();
            int firstSymbol = all.Count;
            while (true)
            {
                int deltaWidth;
                bool ok = huffman ? p.DeltaWidth!.Decode(reader!, out deltaWidth) : arith!.Integer(Jbig2Arith.Iadw, out deltaWidth);
                if (!ok) break;
                if (all.Count + widths.Count >= total) throw PdfReadException.Damaged("A JBIG2 symbol dictionary has more symbols than it says.");
                width += deltaWidth;
                if (width < 0 || width > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 symbol has a bad width.");
                totalWidth += width;
                if (p.Refine)
                {
                    var bitmap = Aggregate(budget, arith, reader, p, all, (int)width, height, codeLength);
                    budget.Keep((long)bitmap.Width * bitmap.Height + 64);
                    all.Add(bitmap);
                }
                else if (huffman)
                {
                    widths.Add((int)width);
                }
                else
                {
                    budget.Keep(width * height + 64);
                    all.Add(Jbig2Generic.Decode(budget, arith!, (int)width, height, p.Template, false, null, p.At));
                }
            }
            if (huffman && !p.Refine) HeightClass(budget, reader!, p, all, widths, height, totalWidth);
        }

        // 6.5.10: runs of symbols that are not exported and are, alternating, over the input symbols and the new ones.
        var flags = new bool[total];
        int index = 0, runs = 0;
        bool current = false;
        while (index < total)
        {
            if (++runs > total + 2) throw PdfReadException.Damaged("A JBIG2 symbol dictionary has bad export flags.");
            int run = Delta(huffman, Jbig2Huffman.Standard(1), arith, reader, Jbig2Arith.Iaex);
            if (run < 0 || run > total - index) throw PdfReadException.Damaged("A JBIG2 symbol dictionary has bad export flags.");
            for (int i = 0; i < run; i++) flags[index++] = current;
            current = !current;
        }
        var exported = new List<Jbig2Bitmap>();
        for (int i = 0; i < total; i++)
        {
            if (flags[i]) exported.Add(all[i]);
        }
        // The list is kept for the segments that refer to it.
        budget.Keep(exported.Count * 8L);
        return exported;
    }

    private static int Delta(bool huffman, Jbig2Huffman? table, Jbig2Arith? arith, Jbig2Reader? reader, int procedure)
    {
        int value;
        bool ok = huffman ? table!.Decode(reader!, out value) : arith!.Integer(procedure, out value);
        if (!ok) throw PdfReadException.Damaged("A JBIG2 symbol dictionary has an out-of-band value where there is none.");
        return value;
    }

    /// <summary>6.5.9: the symbols of one height class are coded side by side in one bitmap, uncompressed or MMR.</summary>
    private static void HeightClass(Jbig2Budget budget, Jbig2Reader reader, Jbig2SymbolParams p, List<Jbig2Bitmap> all, List<int> widths, int height, long totalWidth)
    {
        int size = Delta(true, p.BitmapSize, null, reader, 0);
        reader.ByteAlign();
        if (size < 0 || size > reader.End - reader.Position) throw PdfReadException.Damaged("A JBIG2 symbol bitmap is longer than its segment.");
        if (totalWidth > int.MaxValue) throw Jbig2Budget.TooBig();
        budget.Keep(totalWidth * height + 64 * widths.Count);
        Jbig2Bitmap collective;
        if (size == 0)
        {
            collective = new Jbig2Bitmap((int)totalWidth, height, budget);
            int stride = (int)((totalWidth + 7) / 8);
            if (reader.End - reader.Position < (long)stride * height) throw PdfReadException.Damaged("A JBIG2 symbol bitmap is cut off.");
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < totalWidth; x++) collective.Pixels[y * (int)totalWidth + x] = (byte)((reader.Data[reader.Position + x / 8] >> (7 - (x & 7))) & 1);
                reader.Position += stride;
            }
        }
        else
        {
            collective = Jbig2Generic.Mmr(budget, reader.Data, reader.Position, reader.Position + size, (int)totalWidth, height, out _);
            reader.Position += size;
        }
        int x0 = 0;
        foreach (int width in widths)
        {
            all.Add(collective.Columns(x0, width, budget));
            x0 += width;
        }
    }

    /// <summary>6.5.8.2: a symbol made of other symbols or refined from one.</summary>
    private static Jbig2Bitmap Aggregate(Jbig2Budget budget, Jbig2Arith? arith, Jbig2Reader? reader, Jbig2SymbolParams p, List<Jbig2Bitmap> all,
                                         int width, int height, int codeLength)
    {
        bool huffman = p.Huffman;
        int instances = Delta(huffman, p.AggregateInstances, arith, reader, Jbig2Arith.Iaai);
        var text = new Jbig2TextParams
        {
            Huffman = huffman,
            Refine = true,
            Width = width,
            Height = height,
            Instances = instances,
            ReferenceCorner = 1,
            RefinementTemplate = p.RefinementTemplate,
            RefinementAt = p.RefinementAt,
            Symbols = all,
            SymbolCodeLength = codeLength,
        };
        if (huffman)
        {
            text.FirstS = Jbig2Huffman.Standard(6);
            text.DeltaS = Jbig2Huffman.Standard(8);
            text.DeltaT = Jbig2Huffman.Standard(11);
            text.RefineWidth = text.RefineHeight = text.RefineX = text.RefineY = Jbig2Huffman.Standard(15);
            text.RefineSize = Jbig2Huffman.Standard(1);
        }
        var decoder = new Jbig2Text(budget, arith, reader, text, p.RefineContexts);
        if (instances > 1) return decoder.Decode();
        if (instances < 1) throw PdfReadException.Damaged("A JBIG2 aggregate symbol has no instances.");

        // 6.5.8.2.2: one symbol, refined.
        int id = huffman ? (int)reader!.ReadBits(codeLength) : arith!.Iaid(codeLength);
        int rdx = Delta(huffman, Jbig2Huffman.Standard(15), arith, reader, Jbig2Arith.Iardx);
        int rdy = Delta(huffman, Jbig2Huffman.Standard(15), arith, reader, Jbig2Arith.Iardy);
        if (id < 0 || id >= all.Count) throw PdfReadException.Damaged("A JBIG2 aggregate symbol uses a symbol that is not there.");
        return decoder.RefineWith(all[id], width, height, rdx, rdy);
    }
}
