namespace LazyPDF.Core.Tests;

/// <summary>JBIG2 streams made by the test encoders, written to Tests/Fixtures/golden/filters for both engines to decode.</summary>
internal static class Jbig2Samples
{
    internal sealed record Sample(string Name, byte[] Data, Bm? Expected);

    /// <summary>The globals stream: one symbol dictionary, as a PDF keeps it for every page that uses the symbols.</summary>
    public static byte[] Globals() => Jbig2Segments.Segment(1, 0, Dictionary(Symbols), page: 0);

    public static readonly List<Bm> Symbols = Jbig2SymbolTests.Symbols(12, 21);

    private static byte[] Dictionary(List<Bm> symbols) =>
        Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [.. symbols.Select(_ => true)], 0, null, false, 0, null);

    private static byte[] Page(int width, int height, params byte[][] segments) =>
        Jbig2Segments.Cat([Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(width, height)), .. segments]);

    /// <summary>The page that goes with <see cref="Globals"/>: a text region of its symbols.</summary>
    public static Sample WithGlobals()
    {
        var spec = new TextSpec { Width = 64, Height = 40, Symbols = Symbols, Instances = Jbig2SymbolTests.Placed(Symbols, 64, 40, 2, 24) };
        return new Sample("with-globals.bin", Page(64, 40, Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(spec), [1])), spec.Expected());
    }

    private static byte[] Coded(Bm bm)
    {
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        return e.Finish();
    }

    // An immediate generic region whose header has 0xFFFFFFFF for its length.
    private static byte[] UnknownLength(byte[] data)
    {
        var region = Jbig2Segments.Segment(1, 38, data);
        for (int i = 0; i < 4; i++) region[region.Length - data.Length - 4 + i] = 0xff;
        return region;
    }

    public static IEnumerable<Sample> All()
    {
        for (int template = 0; template < 4; template++)
        {
            var bm = Bm.Text(61, 40, template + 1);
            yield return new Sample($"generic-t{template}.bin", Jbig2Segments.Generic(bm, template, false), bm);
        }
        var repeating = Bm.Repeating(70, 30, 4);
        yield return new Sample("generic-tpgd.bin", Jbig2Segments.Generic(repeating, 0, true), repeating);
        var moved = Bm.Text(90, 33, 11);
        yield return new Sample("generic-at.bin", Jbig2Segments.Generic(moved, 0, false, [-5, -2, 4, -1, 6, -3, -7, -1]), moved);
        var mmr = Bm.Text(61, 40, 61);
        yield return new Sample("generic-mmr.bin", Page(61, 40, Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(mmr, CcittEncoder.Encode(mmr.Packed(), 61, 40), 0, true, false, null))), mmr);

        var stripes = Bm.Text(50, 30, 9);
        var top = stripes.Sub(0, 0, 50, 12);
        var bottom = stripes.Sub(0, 12, 50, 18);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, top, 1, false);
        var f = new ArithEncoder();
        Jbig2Encode.Generic(f, bottom, 1, false);
        yield return new Sample("stripes.bin", Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(50, -1, 0)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(top, e.Finish(), 1, false, false, null, 0, 0)),
            Jbig2Segments.Segment(2, 50, Jbig2Segments.U32(11)),
            Jbig2Segments.Segment(3, 38, Jbig2Segments.GenericData(bottom, f.Finish(), 1, false, false, null, 0, 12)),
            Jbig2Segments.Segment(4, 50, Jbig2Segments.U32(29))), stripes);

        // A refinement of the page, and of an intermediate region.
        var target = Bm.Text(48, 30, 8);
        var coarse = new Bm(48, 30);
        target.Px.CopyTo(coarse.Px, 0);
        for (int i = 0; i < 40; i++) coarse.Px[i * 31 % coarse.Px.Length] ^= 1;
        var c = new ArithEncoder();
        Jbig2Encode.Generic(c, coarse, 2, false);
        var r = new ArithEncoder();
        Jbig2Encode.Refinement(r, target, 1, coarse, 0, 0, true, null);
        yield return new Sample("refine-page.bin", Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(48, 30)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(coarse, c.Finish(), 2, false, false, null)),
            Jbig2Segments.Segment(2, 42, Jbig2Segments.Cat(Jbig2Segments.RegionInfo(48, 30, 0, 0, 4), [3], r.Finish()))), target);
        var c2 = new ArithEncoder();
        Jbig2Encode.Generic(c2, coarse, 0, false);
        var r2 = new ArithEncoder();
        int[] at = [-2, -1, 1, -2];
        Jbig2Encode.Refinement(r2, target, 0, coarse, 0, 0, false, at);
        yield return new Sample("refine-intermediate.bin", Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(48, 30)),
            Jbig2Segments.Segment(1, 36, Jbig2Segments.GenericData(coarse, c2.Finish(), 0, false, false, null)),
            Jbig2Segments.Segment(2, 42, Jbig2Segments.Cat(Jbig2Segments.RegionInfo(48, 30), [0], Jbig2Segments.At(at), r2.Finish()), [1])), target);

        var symbols = Jbig2SymbolTests.Symbols(14, 3);
        var plain = new TextSpec { Width = 80, Height = 60, Symbols = symbols, Instances = Jbig2SymbolTests.Placed(symbols, 80, 60, 5, 40), LogStrip = 2 };
        yield return new Sample("text-arith.bin", Page(80, 60, Jbig2Segments.Segment(1, 0, Dictionary(symbols)), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(plain), [1])), plain.Expected());
        var turned = new TextSpec
        {
            Width = 80, Height = 60, Symbols = symbols, Instances = Jbig2SymbolTests.Placed(symbols, 80, 60, 6, 40), Corner = 2, Transposed = true,
            LogStrip = 1, Op = 2, DsOffset = -3,
        };
        yield return new Sample("text-transposed.bin", Page(80, 60, Jbig2Segments.Segment(1, 0, Dictionary(symbols)), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(turned), [1])), turned.Expected());

        foreach (bool mmrDictionary in new[] { false, true })
        {
            byte[] dictionary = Jbig2SymbolEncode.Huffman([], symbols, [.. symbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, mmrDictionary);
            var huffman = new TextSpec
            {
                Huffman = true, Width = 90, Height = 50, LogStrip = 2, Symbols = symbols, Instances = Jbig2SymbolTests.Placed(symbols, 90, 50, 10, 35),
                SymbolLengths = [.. symbols.Select(_ => Jbig2TextEncode.CodeLength(symbols.Count))],
            };
            yield return new Sample(mmrDictionary ? "text-huffman-mmr.bin" : "text-huffman.bin",
                Page(90, 50, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.HuffmanSegment(huffman, 0), [1])), huffman.Expected());
        }

        var refined = Bm.Text(symbols[3].Width + 2, symbols[3].Height + 1, 31);
        foreach (bool huffman in new[] { false, true })
        {
            var spec = new TextSpec
            {
                Huffman = huffman, Refine = true, Width = 70, Height = 40, Symbols = symbols,
                Instances = [new Instance(0, 4, 4), new Instance(3, 20, 6, refined, 2, 1, 1, 0), new Instance(5, 40, 5), new Instance(7, 50, 22)],
                SymbolLengths = [.. symbols.Select(_ => 4)],
            };
            byte[] text = huffman ? Jbig2TextEncode.HuffmanSegment(spec, 0) : Jbig2TextEncode.ArithmeticSegment(spec);
            yield return new Sample(huffman ? "text-huffman-refine.bin" : "text-refine.bin", Page(70, 40, Jbig2Segments.Segment(1, 0, Dictionary(symbols)), Jbig2Segments.Segment(2, 6, text, [1])), spec.Expected());
        }

        // Custom Huffman tables: a tables segment the text region refers to for its deltas of S.
        var customSymbols = Jbig2SymbolTests.Symbols(10, 5);
        byte[] customDictionary = Jbig2SymbolEncode.Huffman([], customSymbols, [.. customSymbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, false);
        var customLines = new (long, int, int, int)[] { (-4, 3, 2, 0), (0, 3, 3, 0), (8, 2, 4, 0), (24, 3, 2, 0), (-5, 4, 32, 1), (28, 4, 32, 0), (0, 4, 0, 3) };
        var custom = new TextSpec
        {
            Huffman = true, Width = 70, Height = 40, LogStrip = 1, Symbols = customSymbols, Instances = Jbig2SymbolTests.Placed(customSymbols, 70, 40, 3, 25),
            Ds = new HuffEnc(customLines), SymbolLengths = [.. customSymbols.Select(_ => Jbig2TextEncode.CodeLength(customSymbols.Count))],
        };
        yield return new Sample("text-custom.bin", Page(70, 40, Jbig2Segments.Segment(1, 0, customDictionary), Jbig2Segments.Segment(2, 53, HuffEnc.Segment(-4, 28, [3, 3, 2, 3], [2, 3, 4, 2], 4, 4, 4, 3, 3)),
            Jbig2Segments.Segment(3, 6, Jbig2TextEncode.HuffmanSegment(custom, 3 << 2), [1, 2])), custom.Expected());

        // Symbols refined from another and made of two others (more than one instance).
        var basic = Jbig2SymbolTests.Symbols(5, 6);
        var changed = Bm.Text(basic[2].Width, basic[2].Height, 77);
        var parts = new List<Instance> { new(0, 0, 0), new(1, basic[0].Width + 1, 0) };
        var joined = new TextSpec { Width = basic[0].Width + basic[1].Width + 1, Height = Math.Max(basic[0].Height, basic[1].Height), Symbols = basic, Instances = parts }.Expected();
        var added = new List<NewSymbol> { new(changed, 2, 0, 0), new(joined, -1, 0, 0, parts) };
        added = [.. added.OrderBy(a => a.Bitmap.Height)];
        byte[] aggregateDictionary = Jbig2SymbolEncode.Arithmetic(basic, added, [.. Enumerable.Repeat(true, 7)], 0, null, true, 0, null);
        var everything = basic.Concat(added.Select(a => a.Bitmap)).ToList();
        var aggregate = new TextSpec { Width = 80, Height = 50, Symbols = everything, Instances = Jbig2SymbolTests.Placed(everything, 80, 50, 4, 30) };
        yield return new Sample("symbols-aggregate.bin", Page(80, 50, Jbig2Segments.Segment(1, 0, Dictionary(basic)), Jbig2Segments.Segment(2, 0, aggregateDictionary, [1]),
            Jbig2Segments.Segment(3, 6, Jbig2TextEncode.ArithmeticSegment(aggregate), [2])), aggregate.Expected());

        // A dictionary that starts from the contexts the one before it left.
        var firstSymbols = Jbig2SymbolTests.Symbols(6, 31);
        var secondSymbols = Jbig2SymbolTests.Symbols(6, 32);
        var leaving = new ArithEncoder();
        byte[] first = Jbig2SymbolEncode.Arithmetic([], firstSymbols.Select(s => new NewSymbol(s)).ToList(), [.. firstSymbols.Select(_ => true)], 0, null, false, 0, null, leaving, 0x200);
        var continuing = new ArithEncoder { Gb = (byte[])leaving.Gb.Clone(), Gr = (byte[])leaving.Gr.Clone() };
        byte[] second = Jbig2SymbolEncode.Arithmetic(firstSymbols, secondSymbols.Select(s => new NewSymbol(s)).ToList(), [.. Enumerable.Repeat(true, 12)], 0, null, false, 0, null, continuing, 0x100);
        var both = firstSymbols.Concat(secondSymbols).ToList();
        var reused = new TextSpec { Width = 70, Height = 50, Symbols = both, Instances = Jbig2SymbolTests.Placed(both, 70, 50, 8, 30) };
        yield return new Sample("symbols-contexts.bin", Page(70, 50, Jbig2Segments.Segment(1, 0, first), Jbig2Segments.Segment(2, 0, second, [1]),
            Jbig2Segments.Segment(3, 6, Jbig2TextEncode.ArithmeticSegment(reused), [2])), reused.Expected());

        // Huffman symbol codes of 1 to 3 bits, with unused symbols between them.
        var lengthSymbols = Jbig2SymbolTests.Symbols(14, 12);
        var mixed = new TextSpec
        {
            Huffman = true, Width = 70, Height = 40, Symbols = lengthSymbols, SymbolLengths = [2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3],
            Instances = Enumerable.Range(0, 20).Select(i => new Instance(new[] { 0, 1, 12, 13 }[i % 4], 3 + i * 3, 5 + i % 7 * 4)).ToList(),
        };
        byte[] mixedDictionary = Jbig2SymbolEncode.Huffman([], lengthSymbols, [.. lengthSymbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, false);
        yield return new Sample("text-huffman-lengths.bin", Page(70, 40, Jbig2Segments.Segment(1, 0, mixedDictionary), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.HuffmanSegment(mixed, 0), [1])), mixed.Expected());

        // The page operators AND, XNOR and REPLACE.
        var back = Bm.Text(40, 24, 15);
        var layered = new Bm(40, 24);
        back.Px.CopyTo(layered.Px, 0);
        var layers = new List<byte[]> { Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 24)), Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(back, Coded(back), 0, false, false, null)) };
        int number = 2;
        foreach (var (op, x, y) in new[] { (1, 3, 2), (3, 14, 8), (4, 24, 12) })
        {
            var front = Bm.Text(14, 9, 40 + op);
            layers.Add(Jbig2Segments.Segment(number++, 38, Jbig2Segments.GenericData(front, Coded(front), 0, false, false, null, x, y, op)));
            for (int j = 0; j < 9; j++)
            {
                for (int i = 0; i < 14; i++)
                {
                    int d = layered[x + i, y + j], s = front[i, j];
                    layered[x + i, y + j] = op switch { 1 => d & s, 3 => 1 ^ d ^ s, _ => s };
                }
            }
        }
        yield return new Sample("page-operators.bin", Jbig2Segments.Cat([.. layers]), layered);

        // A page that starts black, drawn on with XOR.
        var over = Bm.Text(20, 10, 2);
        var blackPage = new Bm(24, 12);
        Array.Fill(blackPage.Px, (byte)1);
        for (int y = 0; y < 10; y++)
        {
            for (int x = 0; x < 20; x++) blackPage[2 + x, 1 + y] ^= (byte)over[x, y];
        }
        yield return new Sample("page-default-pixel.bin", Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(24, 12, 4)),
            Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(over, Coded(over), 0, false, false, null, 2, 1, 2))), blackPage);

        // Regions with no length in their header: arithmetic and MMR coded.
        var unknown = Bm.Text(40, 25, 4);
        yield return new Sample("generic-unknown-length.bin", Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 25)),
            UnknownLength(Jbig2Segments.Cat(Jbig2Segments.GenericData(unknown, Coded(unknown), 0, false, false, null), Jbig2Segments.U32(25)))), unknown);
        yield return new Sample("generic-unknown-length-mmr.bin", Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(40, 25)),
            UnknownLength(Jbig2Segments.Cat(Jbig2Segments.GenericData(unknown, CcittEncoder.Encode(unknown.Packed(), 40, 25), 0, true, false, null), [0, 0], Jbig2Segments.U32(25)))), unknown);

        // Segment numbers over 256 and over 65536 make referred-to numbers of 2 and 4 bytes; five or more of them use the long header form.
        var wideSymbols = Jbig2SymbolTests.Symbols(8, 9);
        var far1 = new TextSpec { Width = 60, Height = 40, Symbols = wideSymbols, Instances = Jbig2SymbolTests.Placed(wideSymbols, 60, 40, 1, 10) };
        var far2 = new TextSpec { Width = 60, Height = 40, Symbols = wideSymbols, Instances = Jbig2SymbolTests.Placed(wideSymbols, 60, 40, 2, 10) };
        var far3 = new TextSpec { Width = 60, Height = 40, Symbols = wideSymbols, Instances = Jbig2SymbolTests.Placed(wideSymbols, 60, 40, 3, 10) };
        var wideExpected = far1.Expected();
        foreach (var other in new[] { far2.Expected(), far3.Expected() })
        {
            for (int i = 0; i < wideExpected.Px.Length; i++) wideExpected.Px[i] |= other.Px[i];
        }
        yield return new Sample("header-wide.bin", Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(60, 40)),
            Jbig2Segments.Segment(300, 0, Dictionary(wideSymbols)),
            Jbig2Segments.Segment(400, 6, Jbig2TextEncode.ArithmeticSegment(far1), [300]),
            Jbig2Segments.Segment(70000, 6, Jbig2TextEncode.ArithmeticSegment(far2), [300]),
            Jbig2Segments.Segment(70001, 6, Jbig2TextEncode.ArithmeticSegment(far3), [300, 0, 0, 0, 0, 0])), wideExpected);

        yield return WithGlobals();
        foreach (var halftone in Jbig2HalftoneTests.Samples()) yield return halftone;
    }

    /// <summary>One case of the golden input: a file, its globals, bytes to flip as offset:xor, and a length to cut to; - for none.</summary>
    internal sealed record Case(string File, string Globals, string Flips, string Length, string Fit = "-");

    public static IEnumerable<Case> Cases()
    {
        foreach (var sample in All())
        {
            yield return new Case(sample.Name, sample.Name == "with-globals.bin" ? "globals.bin" : "-", "-", "-");
        }
        // Damage: bytes changed in the headers and the data, and streams cut short.
        yield return new Case("generic-t0.bin", "-", "0:ff", "-");
        yield return new Case("generic-t0.bin", "-", "13:80", "-");
        yield return new Case("generic-t0.bin", "-", "40:55,41:aa,42:0f", "-");
        yield return new Case("generic-t0.bin", "-", "-", "30");
        yield return new Case("generic-t0.bin", "-", "-", "60");
        yield return new Case("generic-t0.bin", "-", "-", "120");
        yield return new Case("generic-mmr.bin", "-", "-", "80");
        yield return new Case("text-arith.bin", "-", "-", "200");
        yield return new Case("text-arith.bin", "-", "100:ff", "-");
        yield return new Case("text-huffman.bin", "-", "70:5a", "-");
        yield return new Case("text-huffman-mmr.bin", "-", "-", "150");
        yield return new Case("with-globals.bin", "-", "-", "-");
        yield return new Case("with-globals.bin", "globals.bin", "-", "60");
        yield return new Case("halftone-arith.bin", "-", "-", "100");
        yield return new Case("halftone-mmr.bin", "-", "60:33", "-");
        yield return new Case("stripes.bin", "-", "-", "90");
        // The page cut or padded to the size of the image (the filter is given /Width and /Height as WxH).
        yield return new Case("text-arith.bin", "-", "-", "-", "100x70");
        yield return new Case("text-arith.bin", "-", "-", "-", "60x40");
        yield return new Case("text-arith.bin", "-", "-", "-", "80x30");
        yield return new Case("generic-t0.bin", "-", "-", "-", "61x50");
        yield return new Case("generic-t0.bin", "-", "-", "-", "1x1");
        yield return new Case("with-globals.bin", "globals.bin", "-", "-", "70x44");
    }

    public static string InputText() =>
        "# Cases for the JBIG2 golden test. Ops: jbig2 (file, globals, flips, length, fit). Files are streams as an image holds them (segments one after another,\n" +
        "# no file header) made by the encoders in LazyPDF.Core.Tests; globals is the stream of /JBIG2Globals. A flip is offset:xor with the xor in hex; fit is WxH, the size of the image, or -.\n" +
        "# The result is the page as the filter returns it, black 0.\n" +
        string.Join("", Cases().Select(c => $"jbig2 {c.File} {c.Globals} {c.Flips} {c.Length} {c.Fit}\n"));
}
