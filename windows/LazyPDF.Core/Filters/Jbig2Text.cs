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

// Ported to C# from pdf.js (src/core/jbig2.js: decodeTextRegion, decodeSymbolDictionary) and changed: refinement
// with Huffman coding, all four combination operators, transposed placement as 6.4.5 gives it, retained
// contexts, and limits on the symbols, instances and work a stream may ask for.

namespace LazyPDF.Core;

/// <summary>What the text region decoding procedure (6.4, Table 9) is given.</summary>
internal sealed class Jbig2TextParams
{
    public bool Huffman;
    public bool Refine;
    public int Width;
    public int Height;
    public int DefaultPixel;
    public int Instances;
    public int LogStripSize;
    public int ReferenceCorner;
    public bool Transposed;
    public int CombinationOperator;
    public int DsOffset;
    public int RefinementTemplate;
    public int[] RefinementAt = [-1, -1, -1, -1];
    public List<Jbig2Bitmap> Symbols = [];

    /// <summary>The bits of a symbol id: coded with the IAID procedure, or a fixed length code when there is no <see cref="SymbolIds"/> table.</summary>
    public int SymbolCodeLength;

    public Jbig2Huffman? SymbolIds;
    public Jbig2Huffman? FirstS;
    public Jbig2Huffman? DeltaS;
    public Jbig2Huffman? DeltaT;
    public Jbig2Huffman? RefineWidth;
    public Jbig2Huffman? RefineHeight;
    public Jbig2Huffman? RefineX;
    public Jbig2Huffman? RefineY;
    public Jbig2Huffman? RefineSize;
}

/// <summary>6.4: the symbol instances of a text region, arithmetic or Huffman coded.</summary>
internal sealed class Jbig2Text(Jbig2Budget budget, Jbig2Arith? arith, Jbig2Reader? reader, Jbig2TextParams p, byte[]? refinementContexts)
{
    /// <summary>The most instances a region may have, whatever its header says.</summary>
    public const int MaxInstances = 1 << 22;

    /// <summary>ceil(log2(n)), the length of the codes of n symbols.</summary>
    public static int CodeLength(int n) => n <= 1 ? 0 : 32 - System.Numerics.BitOperations.LeadingZeroCount((uint)(n - 1));

    private int Value(Jbig2Huffman? table, int procedure)
    {
        int value;
        bool ok = p.Huffman ? table!.Decode(reader!, out value) : arith!.Integer(procedure, out value);
        if (!ok) throw PdfReadException.Damaged("A JBIG2 text region has an out-of-band value where there is none.");
        return value;
    }

    public Jbig2Bitmap Decode()
    {
        if (p.Instances < 0 || p.Instances > MaxInstances) throw PdfReadException.Damaged("A JBIG2 text region has too many symbol instances.");
        var bitmap = new Jbig2Bitmap(p.Width, p.Height, budget);
        if (p.DefaultPixel != 0) bitmap.Fill(1);
        int stripSize = 1 << p.LogStripSize;
        bool bottom = (p.ReferenceCorner & 1) == 0, right = (p.ReferenceCorner & 2) != 0;

        long stripT = -(long)Value(p.DeltaT, Jbig2Arith.Iadt);
        long firstS = 0;
        int placed = 0;
        while (placed < p.Instances)
        {
            stripT += Value(p.DeltaT, Jbig2Arith.Iadt);
            firstS += Value(p.FirstS, Jbig2Arith.Iafs);
            long currentS = firstS;
            while (true)
            {
                int currentT = 0;
                if (stripSize > 1) currentT = p.Huffman ? (int)reader!.ReadBits(p.LogStripSize) : Value(null, Jbig2Arith.Iait);
                long t = stripSize * stripT + currentT;
                var symbol = SymbolAt(SymbolId());
                if (p.Refine && Refined()) symbol = Refine(symbol);
                int w = symbol.Width, h = symbol.Height;

                // 6.4.5 step vi, then viii: the reference corner is at (S, T), or at (T, S) when transposed.
                if (p.Transposed ? bottom : right) currentS += (p.Transposed ? h : w) - 1;
                long left = p.Transposed ? t : currentS;
                long top = p.Transposed ? currentS : t;
                if (right) left -= w - 1;
                if (bottom) top -= h - 1;
                budget.Work((long)w * h);
                if (left > int.MinValue && left < int.MaxValue && top > int.MinValue && top < int.MaxValue)
                    bitmap.Compose(symbol, (int)left, (int)top, p.CombinationOperator);
                // Step x
                if (p.Transposed ? !bottom : !right) currentS += (p.Transposed ? h : w) - 1;
                placed++;

                if (!Delta(p.DeltaS, Jbig2Arith.Iads, out int deltaS) || placed >= p.Instances) break;
                currentS += deltaS + p.DsOffset;
            }
        }
        return bitmap;
    }

    private int SymbolId()
    {
        if (!p.Huffman) return arith!.Iaid(p.SymbolCodeLength);
        if (p.SymbolIds is null) return (int)reader!.ReadBits(p.SymbolCodeLength);
        return Value(p.SymbolIds, 0);
    }

    private Jbig2Bitmap SymbolAt(int id) =>
        id >= 0 && id < p.Symbols.Count ? p.Symbols[id] : throw PdfReadException.Damaged("A JBIG2 text region uses a symbol that is not there.");

    private bool Refined() => p.Huffman ? reader!.ReadBit() != 0 : Value(null, Jbig2Arith.Iari) != 0;

    private bool Delta(Jbig2Huffman? table, int procedure, out int value) =>
        p.Huffman ? table!.Decode(reader!, out value) : arith!.Integer(procedure, out value);

    /// <summary>6.4.11: the symbol refined by a small bitmap coded in the region.</summary>
    private Jbig2Bitmap Refine(Jbig2Bitmap symbol)
    {
        int rdw = Value(p.RefineWidth, Jbig2Arith.Iardw);
        int rdh = Value(p.RefineHeight, Jbig2Arith.Iardh);
        int rdx = Value(p.RefineX, Jbig2Arith.Iardx);
        int rdy = Value(p.RefineY, Jbig2Arith.Iardy);
        long width = (long)symbol.Width + rdw, height = (long)symbol.Height + rdh;
        if (width < 0 || height < 0 || width > int.MaxValue || height > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 refined symbol has a bad size.");
        budget.Work(width * height);
        return RefineWith(symbol, (int)width, (int)height, (rdw >> 1) + rdx, (rdh >> 1) + rdy);
    }

    /// <summary>The refinement coded in the arithmetic data, or in a size and a block of its own when Huffman coded.</summary>
    public Jbig2Bitmap RefineWith(Jbig2Bitmap reference, int width, int height, int dx, int dy)
    {
        if (!p.Huffman) return Jbig2Generic.Refine(budget, arith!, width, height, p.RefinementTemplate, reference, dx, dy, false, p.RefinementAt);
        int size = Value(p.RefineSize, 0);
        reader!.ByteAlign();
        if (size < 0 || size > reader.End - reader.Position) throw PdfReadException.Damaged("A JBIG2 refinement is longer than its segment.");
        var block = new Jbig2Arith(reader.Data, reader.Position, reader.Position + size) { Gr = refinementContexts! };
        var result = Jbig2Generic.Refine(budget, block, width, height, p.RefinementTemplate, reference, dx, dy, false, p.RefinementAt);
        reader.Position += size;
        return result;
    }
}
