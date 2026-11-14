namespace LazyPDF.Core.Tests;

// Symbol dictionaries, text regions and the Huffman tables they use, run backwards for the decoder tests.

/// <summary>Bits, most significant first.</summary>
internal sealed class BitOut
{
    private readonly List<byte> _bytes = [];
    private int _current;
    private int _count;

    public void Put(long value, int count)
    {
        for (int i = count - 1; i >= 0; i--)
        {
            _current = (_current << 1) | (int)(value >> i & 1);
            if (++_count == 8) Flush();
        }
    }

    public void Align()
    {
        while (_count != 0) Put(0, 1);
    }

    public void Bytes(byte[] bytes)
    {
        Align();
        _bytes.AddRange(bytes);
    }

    private void Flush()
    {
        _bytes.Add((byte)_current);
        _current = 0;
        _count = 0;
    }

    public byte[] ToArray()
    {
        Align();
        return [.. _bytes];
    }
}

/// <summary>A prefix code table written the way Annex B gives it.</summary>
internal sealed class HuffEnc((long Low, int Prefix, int Range, int Kind)[] lines)
{
    private readonly long[] _codes = new Jbig2Huffman(lines).Codes;

    public (long Low, int Prefix, int Range, int Kind)[] Lines => lines;

    public static HuffEnc Std(int number) => new(Jbig2Huffman.StandardTable(number));

    /// <summary>The value, or the out-of-band value for null.</summary>
    public void Put(BitOut w, long? value)
    {
        for (int i = 0; i < lines.Length; i++)
        {
            var (low, prefix, range, kind) = lines[i];
            if (prefix == 0) continue;
            long offset;
            if (value is null)
            {
                if (kind != 3) continue;
                offset = 0;
            }
            else if (kind == 3) continue;
            else if (kind == 1)
            {
                if (value > low) continue;
                offset = low - value.Value;
            }
            else
            {
                if (value < low || (range < 32 && value >= low + (1L << range))) continue;
                offset = value.Value - low;
            }
            w.Put(_codes[i], prefix);
            w.Put(offset, range);
            return;
        }
        throw new InvalidOperationException($"No line for {value}.");
    }

    /// <summary>A tables segment's data (B.2) for lines in the form that segment has: normal ranges, then lower, upper and maybe out of band.</summary>
    public static byte[] Segment(long lowest, long highest, int[] prefixes, int[] ranges, int lowerPrefix, int upperPrefix, int? oobPrefix, int prefixBits, int rangeBits)
    {
        var w = new BitOut();
        for (int i = 0; i < prefixes.Length; i++)
        {
            w.Put(prefixes[i], prefixBits);
            w.Put(ranges[i], rangeBits);
        }
        w.Put(lowerPrefix, prefixBits);
        w.Put(upperPrefix, prefixBits);
        if (oobPrefix is { } oob) w.Put(oob, prefixBits);
        return Jbig2Segments.Cat([(byte)((oobPrefix is null ? 0 : 1) | (prefixBits - 1) << 1 | (rangeBits - 1) << 4)], Jbig2Segments.U32(lowest), Jbig2Segments.U32(highest), w.ToArray());
    }
}

internal sealed record Instance(int Id, int X, int Y, Bm? Refined = null, int Rdw = 0, int Rdh = 0, int Rdx = 0, int Rdy = 0);

/// <summary>The parameters of a text region (Table 9) and the instances to code; X and Y are where the reference corner goes.</summary>
internal sealed class TextSpec
{
    public bool Huffman;
    public bool Refine;
    public int Width, Height;
    public int LogStrip;
    public int Corner = 1;
    public bool Transposed;
    public int Op;
    public int DefaultPixel;
    public int DsOffset;
    public int RefineTemplate;
    public int[] RefineAt = [-1, -1, -1, -1];
    public List<Bm> Symbols = [];
    public List<Instance> Instances = [];

    // Huffman: the tables, and the length of each symbol's code (0 for a symbol that is not used).
    public HuffEnc Fs = HuffEnc.Std(6), Ds = HuffEnc.Std(8), Dt = HuffEnc.Std(11);
    public HuffEnc Rdw = HuffEnc.Std(14), Rdh = HuffEnc.Std(14), Rdx = HuffEnc.Std(14), Rdy = HuffEnc.Std(14), Rsize = HuffEnc.Std(1);
    public int[]? SymbolLengths;

    public bool Bottom => (Corner & 1) == 0;
    public bool Right => (Corner & 2) != 0;

    /// <summary>The region these instances make: each symbol with its reference corner (6.4.5 step viii) at the instance's point.</summary>
    public Bm Expected()
    {
        var bm = new Bm(Width, Height);
        if (DefaultPixel != 0) Array.Fill(bm.Px, (byte)1);
        foreach (var i in Instances)
        {
            var s = i.Refined ?? Symbols[i.Id];
            int left = Right ? i.X - (s.Width - 1) : i.X;
            int top = Bottom ? i.Y - (s.Height - 1) : i.Y;
            for (int y = 0; y < s.Height; y++)
            {
                for (int x = 0; x < s.Width; x++)
                {
                    int px = left + x, py = top + y;
                    if (px < 0 || py < 0 || px >= Width || py >= Height) continue;
                    int d = bm[px, py], v = s[x, y];
                    bm[px, py] = Op switch { 0 => d | v, 1 => d & v, 2 => d ^ v, _ => 1 ^ d ^ v };
                }
            }
        }
        return bm;
    }

    /// <summary>The flags word of a text region segment (7.4.3.1.1).</summary>
    public int Flags => (Huffman ? 1 : 0) | (Refine ? 2 : 0) | LogStrip << 2 | Corner << 4 | (Transposed ? 64 : 0) | Op << 7 | DefaultPixel << 9
        | (DsOffset & 31) << 10 | RefineTemplate << 15;
}

internal static class Jbig2TextEncode
{
    /// <summary>The coded instances of 6.4.5, after the segment's header fields, to the arithmetic encoder or the bit writer.</summary>
    public static void Instances(TextSpec s, ArithEncoder? e, BitOut? w, int symbolCodeLength, byte[]? sharedRefineContexts = null)
    {
        int strip = 1 << s.LogStrip;
        void Int(int procedure, HuffEnc table, long? value)
        {
            if (s.Huffman) table.Put(w!, value); else e!.Integer(procedure, value);
        }
        var order = s.Instances
            .Select(i => (Instance: i, T: s.Transposed ? i.X : i.Y, S: s.Transposed ? i.Y : i.X))
            .OrderBy(t => Strip(t.T)).ThenBy(t => t.S).ToList();
        int Strip(int t) => (int)Math.Floor((double)t / strip);

        // The standard Huffman tables for the strip deltas start at 1, so a Huffman coded region starts one strip above its first.
        int initial = s.Huffman && order.Count > 0 ? Math.Max(1, 1 - Strip(order[0].T)) : 0;
        Int(Jbig2Arith.Iadt, s.Dt, initial);
        int stripNow = -initial;
        long firstS = 0;
        var refineContexts = sharedRefineContexts ?? new byte[1 << 13];
        for (int at = 0; at < order.Count;)
        {
            int stripIndex = Strip(order[at].T);
            int end = at;
            while (end < order.Count && Strip(order[end].T) == stripIndex) end++;
            Int(Jbig2Arith.Iadt, s.Dt, stripIndex - stripNow);
            stripNow = stripIndex;
            long previousEnd = 0;
            for (int k = at; k < end; k++)
            {
                var (inst, t, sCoord) = order[k];
                var shape = inst.Refined ?? s.Symbols[inst.Id];
                int extent = s.Transposed ? shape.Height : shape.Width;
                long cur = (s.Transposed ? s.Bottom : s.Right) ? sCoord - (extent - 1) : sCoord;
                if (k == at)
                {
                    Int(Jbig2Arith.Iafs, s.Fs, cur - firstS);
                    firstS = cur;
                }
                else
                {
                    Int(Jbig2Arith.Iads, s.Ds, cur - previousEnd - s.DsOffset);
                }
                previousEnd = cur + extent - 1;
                if (strip > 1)
                {
                    if (s.Huffman) w!.Put(t - stripIndex * strip, s.LogStrip);
                    else e!.Integer(Jbig2Arith.Iait, t - stripIndex * strip);
                }
                if (s.Huffman)
                {
                    int length = s.SymbolLengths![inst.Id];
                    w!.Put(SymbolCodes(s.SymbolLengths)[inst.Id], length);
                }
                else e!.Iaid(symbolCodeLength, inst.Id);
                if (s.Refine)
                {
                    int ri = inst.Refined is null ? 0 : 1;
                    if (s.Huffman) w!.Put(ri, 1); else e!.Integer(Jbig2Arith.Iari, ri);
                    if (ri != 0)
                    {
                        Int(Jbig2Arith.Iardw, s.Rdw, inst.Rdw);
                        Int(Jbig2Arith.Iardh, s.Rdh, inst.Rdh);
                        Int(Jbig2Arith.Iardx, s.Rdx, inst.Rdx);
                        Int(Jbig2Arith.Iardy, s.Rdy, inst.Rdy);
                        int dx = (inst.Rdw >> 1) + inst.Rdx, dy = (inst.Rdh >> 1) + inst.Rdy;
                        if (s.Huffman)
                        {
                            var block = new ArithEncoder { Gr = refineContexts };
                            Jbig2Encode.Refinement(block, inst.Refined!, s.RefineTemplate, s.Symbols[inst.Id], dx, dy, false, s.RefineAt);
                            byte[] bytes = block.Finish();
                            s.Rsize.Put(w!, bytes.Length);
                            w!.Bytes(bytes);
                        }
                        else Jbig2Encode.Refinement(e!, inst.Refined!, s.RefineTemplate, s.Symbols[inst.Id], dx, dy, false, s.RefineAt);
                    }
                }
            }
            // The strip ends with the out-of-band delta.
            Int(Jbig2Arith.Iads, s.Ds, null);
            at = end;
        }
    }

    /// <summary>The codes B.3 gives symbols of these lengths.</summary>
    public static long[] SymbolCodes(int[] lengths) => new Jbig2Huffman(lengths.Select((l, i) => ((long)i, l, 0, 0)).ToArray()).Codes;

    /// <summary>The symbol id table of 7.4.3.1.7 for these code lengths: run codes with the lengths 1 and 2, coded after them.</summary>
    public static void SymbolIdTable(BitOut w, int[] lengths)
    {
        // Runcodes in use: each length that occurs, 32 for repeating the last one, 33 for runs of zeros.
        var runLengths = new int[35];
        foreach (int l in lengths.Distinct()) runLengths[l] = 4;
        runLengths[32] = 4;
        runLengths[33] = 4;
        for (int i = 0; i < 35; i++) w.Put(runLengths[i], 4);
        var codes = new Jbig2Huffman(runLengths.Select((l, i) => ((long)i, l, 0, 0)).ToArray()).Codes;
        void Run(int value) => w.Put(codes[value], runLengths[value]);
        for (int i = 0; i < lengths.Length;)
        {
            int j = i;
            while (j < lengths.Length && lengths[j] == lengths[i]) j++;
            int same = j - i;
            if (lengths[i] == 0 && same >= 3)
            {
                int n = Math.Min(same, 10);
                Run(33);
                w.Put(n - 3, 3);
                i += n;
            }
            else if (i > 0 && lengths[i] == lengths[i - 1] && same >= 3)
            {
                int n = Math.Min(same, 6);
                Run(32);
                w.Put(n - 3, 2);
                i += n;
            }
            else
            {
                Run(lengths[i]);
                i++;
            }
        }
        w.Align();
    }

    public static int CodeLength(int n) => n <= 1 ? 0 : (int)Math.Ceiling(Math.Log2(n));

    /// <summary>The data of a text region segment (7.4.3) with arithmetic coding.</summary>
    public static byte[] ArithmeticSegment(TextSpec s)
    {
        var e = new ArithEncoder();
        Instances(s, e, null, CodeLength(s.Symbols.Count));
        return Header(s, s.Symbols.Count, 0, e.Finish());
    }

    /// <summary>The data of a text region segment with Huffman coding, tables as <paramref name="s"/> names them.</summary>
    public static byte[] HuffmanSegment(TextSpec s, int huffmanFlags)
    {
        var w = new BitOut();
        SymbolIdTable(w, s.SymbolLengths!);
        Instances(s, null, w, 0);
        return Header(s, s.Symbols.Count, huffmanFlags, w.ToArray());
    }

    private static byte[] Header(TextSpec s, int symbolCount, int huffmanFlags, byte[] body) =>
        Jbig2Segments.Cat(
            Jbig2Segments.RegionInfo(s.Width, s.Height),
            Jbig2Segments.U16(s.Flags),
            s.Huffman ? Jbig2Segments.U16(huffmanFlags) : [],
            s.Refine && s.RefineTemplate == 0 ? Jbig2Segments.At(s.RefineAt) : [],
            Jbig2Segments.U32(s.Instances.Count),
            body);
}

/// <summary>A symbol of a dictionary: coded directly, refined from an earlier symbol, or made of other symbols.</summary>
internal sealed record NewSymbol(Bm Bitmap, int RefineId = -1, int Rdx = 0, int Rdy = 0, List<Instance>? Aggregate = null);

internal static class Jbig2SymbolEncode
{
    /// <summary>
    /// A symbol dictionary segment's data (7.4.2). The new symbols are in order of height; <paramref name="exported"/> says which
    /// of the input and new symbols are exported, in that order.
    /// </summary>
    public static byte[] Arithmetic(List<Bm> input, List<NewSymbol> added, bool[] exported, int template, int[]? at, bool refine, int refineTemplate, int[]? refineAt)
    {
        at ??= Jbig2Encode.DefaultAt(template);
        refineAt ??= [-1, -1, -1, -1];
        var e = new ArithEncoder();
        int total = input.Count + added.Count;
        int codeLength = Jbig2TextEncode.CodeLength(total);
        var all = new List<Bm>(input);
        int height = 0;
        for (int i = 0; i < added.Count;)
        {
            int h = added[i].Bitmap.Height;
            e.Integer(ArithEncoder.Iadh, h - height);
            height = h;
            int width = 0;
            for (; i < added.Count && added[i].Bitmap.Height == h; i++)
            {
                var symbol = added[i];
                e.Integer(ArithEncoder.Iadw, symbol.Bitmap.Width - width);
                width = symbol.Bitmap.Width;
                if (!refine) Jbig2Encode.Generic(e, symbol.Bitmap, template, false, at);
                else if (symbol.Aggregate is null)
                {
                    e.Integer(ArithEncoder.Iaai, 1);
                    e.Iaid(codeLength, symbol.RefineId);
                    e.Integer(ArithEncoder.Iardx, symbol.Rdx);
                    e.Integer(ArithEncoder.Iardy, symbol.Rdy);
                    Jbig2Encode.Refinement(e, symbol.Bitmap, refineTemplate, all[symbol.RefineId], symbol.Rdx, symbol.Rdy, false, refineAt);
                }
                else
                {
                    e.Integer(ArithEncoder.Iaai, symbol.Aggregate.Count);
                    var text = new TextSpec
                    {
                        Refine = true, Width = symbol.Bitmap.Width, Height = symbol.Bitmap.Height, Corner = 1, Symbols = all,
                        Instances = symbol.Aggregate, RefineTemplate = refineTemplate, RefineAt = refineAt,
                    };
                    Jbig2TextEncode.Instances(text, e, null, codeLength);
                }
                all.Add(symbol.Bitmap);
            }
            e.Integer(ArithEncoder.Iadw, null);
        }
        ExportFlags(exported, run => e.Integer(ArithEncoder.Iaex, run));
        return Cat(Flags(false, refine, template, refineTemplate), at, refine && refineTemplate == 0 ? refineAt : [], exported, added.Count, e.Finish());
    }

    private static int Flags(bool huffman, bool refine, int template, int refineTemplate) =>
        (huffman ? 1 : 0) | (refine ? 2 : 0) | template << 10 | refineTemplate << 12;

    private static void ExportFlags(bool[] exported, Action<int> put)
    {
        bool current = false;
        for (int i = 0; i < exported.Length;)
        {
            int j = i;
            while (j < exported.Length && exported[j] == current) j++;
            put(j - i);
            i = j;
            current = !current;
        }
    }

    private static byte[] Cat(int flags, int[] at, int[] refineAt, bool[] exported, int added, byte[] body) =>
        Jbig2Segments.Cat(Jbig2Segments.U16(flags), (flags & 1) != 0 ? [] : Jbig2Segments.At(at), (flags & 2) != 0 && (flags >> 12 & 1) == 0 ? Jbig2Segments.At(refineAt) : [],
            Jbig2Segments.U32(exported.Count(x => x)), Jbig2Segments.U32(added), body);

    /// <summary>
    /// A Huffman coded symbol dictionary without refinement: each height class has its symbols side by side in one bitmap,
    /// uncompressed or as MMR data.
    /// </summary>
    public static byte[] Huffman(List<Bm> input, List<Bm> added, bool[] exported, HuffEnc dh, HuffEnc dw, int flagBits, bool mmr)
    {
        var w = new BitOut();
        int height = 0;
        for (int i = 0; i < added.Count;)
        {
            int h = added[i].Height;
            dh.Put(w, h - height);
            height = h;
            int width = 0, first = i;
            for (; i < added.Count && added[i].Height == h; i++)
            {
                dw.Put(w, added[i].Width - width);
                width = added[i].Width;
            }
            dw.Put(w, null);
            int total = added.Skip(first).Take(i - first).Sum(b => b.Width);
            var collective = new Bm(total, h);
            int x0 = 0;
            for (int k = first; k < i; k++)
            {
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < added[k].Width; x++) collective[x0 + x, y] = added[k][x, y];
                }
                x0 += added[k].Width;
            }
            if (mmr)
            {
                byte[] coded = CcittEncoder.Encode(collective.Packed(), total, h);
                HuffEnc.Std(1).Put(w, coded.Length);
                w.Bytes(coded);
            }
            else
            {
                HuffEnc.Std(1).Put(w, 0);
                w.Align();
                int stride = (total + 7) / 8;
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < stride * 8; x++) w.Put(x < total ? collective[x, y] : 0, 1);
                }
            }
        }
        ExportFlags(exported, run => HuffEnc.Std(1).Put(w, run));
        return Cat(Flags(true, false, 0, 0) | flagBits, [], [], exported, added.Count, w.ToArray());
    }
}
