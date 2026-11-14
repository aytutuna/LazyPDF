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

        yield return WithGlobals();
        foreach (var halftone in Jbig2HalftoneTests.Samples()) yield return halftone;
    }

    /// <summary>One case of the golden input: a file, its globals, bytes to flip as offset:xor, and a length to cut to; - for none.</summary>
    internal sealed record Case(string File, string Globals, string Flips, string Length);

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
    }

    public static string InputText() =>
        "# Cases for the JBIG2 golden test. Ops: jbig2 (file, globals, flips, length). Files are streams as an image holds them (segments one after another,\n" +
        "# no file header) made by the encoders in LazyPDF.Core.Tests; globals is the stream of /JBIG2Globals. A flip is offset:xor with the xor in hex.\n" +
        "# The result is the page as the filter returns it, black 0.\n" +
        string.Join("", Cases().Select(c => $"jbig2 {c.File} {c.Globals} {c.Flips} {c.Length}\n"));
}
