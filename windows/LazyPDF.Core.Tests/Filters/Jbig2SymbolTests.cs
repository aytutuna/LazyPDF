using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2SymbolTests
{
    private static byte[] Decode(byte[] stream) => Jbig2GenericTests.Decode(stream);

    /// <summary>Small bitmaps in order of height, then width, the order a dictionary codes them in.</summary>
    internal static List<Bm> Symbols(int count, int seed)
    {
        var random = new Random(seed);
        var symbols = new List<(int W, int H)>();
        for (int i = 0; i < count; i++) symbols.Add((random.Next(3, 13), random.Next(2, 5) * 3));
        return symbols.OrderBy(s => s.H).ThenBy(s => s.W).Select((s, i) => Bm.Text(s.W, s.H, seed * 100 + i)).ToList();
    }

    internal static List<Instance> Placed(List<Bm> symbols, int width, int height, int seed, int count)
    {
        var random = new Random(seed);
        var instances = new List<Instance>();
        for (int i = 0; i < count; i++) instances.Add(new Instance(random.Next(symbols.Count), random.Next(-3, width + 3), random.Next(-3, height + 3)));
        return instances;
    }

    private static byte[] Page(int width, int height, params byte[][] segments) =>
        Jbig2Segments.Cat([Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(width, height)), .. segments]);

    private static byte[] ArithmeticDictionary(List<Bm> symbols, int number = 1, int template = 0) =>
        Jbig2Segments.Segment(number, 0, Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [.. symbols.Select(_ => true)], template, null, false, 0, null));

    public static IEnumerable<object[]> TextCases()
    {
        foreach (int corner in new[] { 0, 1, 2, 3 })
        {
            foreach (bool transposed in new[] { false, true })
            {
                yield return [corner, transposed, 0, 0, 0, 0];
            }
        }
        foreach (int log in new[] { 1, 2, 3 }) yield return [1, false, log, 0, 0, 0];
        foreach (int op in new[] { 1, 2, 3 }) yield return [3, false, 0, op, 0, op == 1 ? 1 : 0];
        yield return [0, true, 2, 2, -3, 1];
        yield return [2, false, 1, 0, 4, 0];
        yield return [1, true, 3, 3, -16, 1];
    }

    [Theory]
    [MemberData(nameof(TextCases))]
    public void TextRegionPlacesSymbolsOfAnArithmeticDictionary(int corner, bool transposed, int logStrip, int op, int dsOffset, int defaultPixel)
    {
        var symbols = Symbols(14, 3);
        var spec = new TextSpec
        {
            Width = 80, Height = 60, Corner = corner, Transposed = transposed, LogStrip = logStrip, Op = op, DsOffset = dsOffset, DefaultPixel = defaultPixel,
            Symbols = symbols, Instances = Placed(symbols, 80, 60, corner * 7 + logStrip, 40),
        };
        var stream = Page(80, 60, ArithmeticDictionary(symbols), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(spec), [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public void DictionaryTemplatesAndAdaptivePixels(int template)
    {
        var symbols = Symbols(9, 8);
        var spec = new TextSpec { Width = 50, Height = 40, Symbols = symbols, Instances = Placed(symbols, 50, 40, 5, 20) };
        var stream = Page(50, 40, ArithmeticDictionary(symbols, 1, template), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(spec), [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Fact]
    public void DictionariesCanBuildOnEachOtherAndExportSome()
    {
        var first = Symbols(6, 4);
        var second = Symbols(5, 9);
        // The second dictionary takes the first's symbols in and exports half of them and the first two of its own.
        bool[] exported = [true, false, true, false, true, false, true, true, false, false, false];
        byte[] dictionary = Jbig2SymbolEncode.Arithmetic(first, second.Select(s => new NewSymbol(s)).ToList(), exported, 0, null, false, 0, null);
        var visible = new List<Bm> { first[0], first[2], first[4], second[0], second[1] };
        var spec = new TextSpec { Width = 60, Height = 50, Symbols = visible, Instances = Placed(visible, 60, 50, 6, 25) };
        var stream = Page(60, 50, ArithmeticDictionary(first), Jbig2Segments.Segment(2, 0, dictionary, [1]), Jbig2Segments.Segment(3, 6, Jbig2TextEncode.ArithmeticSegment(spec), [2]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));

        // A text region that refers to both dictionaries has the symbols of the first and then those exported by the second.
        var both = first.Concat(visible).ToList();
        var spec2 = new TextSpec { Width = 60, Height = 50, Symbols = both, Instances = Placed(both, 60, 50, 7, 25) };
        var stream2 = Page(60, 50, ArithmeticDictionary(first), Jbig2Segments.Segment(2, 0, dictionary, [1]), Jbig2Segments.Segment(3, 6, Jbig2TextEncode.ArithmeticSegment(spec2), [1, 2]));
        Assert.Equal(spec2.Expected().Packed(), Decode(stream2));
    }

    [Theory]
    [InlineData(false, 0, 0, 6, 8, 11)]
    [InlineData(true, 1, 1, 7, 9, 12)]
    [InlineData(false, 1, 0, 6, 10, 13)]
    public void HuffmanDictionaryAndTextRegion(bool mmr, int dhSelector, int dwSelector, int fsTable, int dsTable, int dtTable)
    {
        var symbols = Symbols(13, 2);
        byte[] dictionary = Jbig2SymbolEncode.Huffman([], symbols, [.. symbols.Select(_ => true)], HuffEnc.Std(4 + dhSelector), HuffEnc.Std(2 + dwSelector),
            dhSelector << 2 | dwSelector << 4, mmr);
        var spec = new TextSpec
        {
            Huffman = true, Width = 90, Height = 50, Corner = 1, LogStrip = 2, Symbols = symbols, Instances = Placed(symbols, 90, 50, 10, 35),
            Fs = HuffEnc.Std(fsTable), Ds = HuffEnc.Std(dsTable), Dt = HuffEnc.Std(dtTable),
            SymbolLengths = [.. symbols.Select(_ => Jbig2TextEncode.CodeLength(symbols.Count))],
        };
        int huffmanFlags = (fsTable - 6) | (dsTable - 8) << 2 | (dtTable - 11) << 4;
        var stream = Page(90, 50, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.HuffmanSegment(spec, huffmanFlags), [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Fact]
    public void RefinementSelectionsOfARegionThatDoesNotRefineAreIgnored()
    {
        var symbols = Symbols(6, 4);
        byte[] dictionary = Jbig2SymbolEncode.Huffman([], symbols, [.. symbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, false);
        var spec = new TextSpec
        {
            Huffman = true, Width = 50, Height = 30, Symbols = symbols, Instances = Placed(symbols, 50, 30, 2, 12),
            SymbolLengths = [.. symbols.Select(_ => Jbig2TextEncode.CodeLength(symbols.Count))],
        };
        // Custom tables selected for values that are never coded, with no table segment to supply them.
        var stream = Page(50, 30, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.HuffmanSegment(spec, 0x7fc0), [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Fact]
    public void HuffmanSymbolCodesOfDifferentLengthsWithRunsAndUnusedSymbols()
    {
        var symbols = Symbols(14, 12);
        // Symbols 2 to 12 are never used and have no code; the others have codes of 1 to 3 bits.
        int[] lengths = [2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3];
        var spec = new TextSpec
        {
            Huffman = true, Width = 70, Height = 40, Symbols = symbols, SymbolLengths = lengths,
            Instances = Enumerable.Range(0, 20).Select(i => new Instance(new[] { 0, 1, 12, 13 }[i % 4], 3 + i * 3, 5 + i % 7 * 4)).ToList(),
        };
        byte[] dictionary = Jbig2SymbolEncode.Huffman([], symbols, [.. symbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, false);
        var stream = Page(70, 40, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.HuffmanSegment(spec, 0), [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Fact]
    public void CustomHuffmanTablesFromATablesSegment()
    {
        var symbols = Symbols(10, 5);
        byte[] dictionary = Jbig2SymbolEncode.Huffman([], symbols, [.. symbols.Select(_ => true)], HuffEnc.Std(4), HuffEnc.Std(2), 0, false);
        // Values -4 to 27 in ranges of 4 and 8 and 16 and 4, lower and upper ranges, and an out of band value (B.2).
        int[] prefixes = [3, 3, 2, 3];
        int[] ranges = [2, 3, 4, 2];
        // The lines this makes: -4..-1, 0..7, 8..23, 24..27, lower than -4, 28 and up, out of band.
        var lines = new (long, int, int, int)[]
        {
            (-4, 3, 2, 0), (0, 3, 3, 0), (8, 2, 4, 0), (24, 3, 2, 0), (-5, 4, 32, 1), (28, 4, 32, 0), (0, 4, 0, 3),
        };
        byte[] table = HuffEnc.Segment(-4, 28, prefixes, ranges, 4, 4, 4, 3, 3);
        var spec = new TextSpec
        {
            Huffman = true, Width = 70, Height = 40, LogStrip = 1, Symbols = symbols, Instances = Placed(symbols, 70, 40, 3, 25),
            Ds = new HuffEnc(lines), SymbolLengths = [.. symbols.Select(_ => Jbig2TextEncode.CodeLength(symbols.Count))],
        };
        var stream = Page(70, 40, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 53, table),
            Jbig2Segments.Segment(3, 6, Jbig2TextEncode.HuffmanSegment(spec, 3 << 2), [1, 2]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void RefinedAndAggregateSymbolsOfAnArithmeticDictionary(int refineTemplate)
    {
        var basic = Symbols(5, 6);
        // A refined symbol is one of the basic ones with a pixel changed; an aggregate is made of basic symbols side by side.
        var changed = Bm.Text(basic[2].Width, basic[2].Height, 77);
        var wide = new Bm(basic[0].Width + basic[1].Width + 1, Math.Max(basic[0].Height, basic[1].Height));
        var parts = new List<Instance> { new(0, 0, 0), new(1, basic[0].Width + 1, 0) };
        var aggregate = new TextSpec { Width = wide.Width, Height = wide.Height, Symbols = basic, Instances = parts }.Expected();
        var added = new List<NewSymbol> { new(changed, 2, 0, 0), new(aggregate, -1, 0, 0, parts) };
        added = [.. added.OrderBy(a => a.Bitmap.Height)];
        bool[] exported = [.. Enumerable.Repeat(true, 5 + 2)];
        byte[] dictionary = Jbig2SymbolEncode.Arithmetic(basic, added, exported, 0, null, true, refineTemplate, null);
        var all = basic.Concat(added.Select(a => a.Bitmap)).ToList();
        var spec = new TextSpec { Width = 80, Height = 50, Symbols = all, Instances = Placed(all, 80, 50, 4, 30) };
        var stream = Page(80, 50, Jbig2Segments.Segment(1, 0, ArithmeticDictionaryBytes(basic)), Jbig2Segments.Segment(2, 0, dictionary, [1]),
            Jbig2Segments.Segment(3, 6, Jbig2TextEncode.ArithmeticSegment(spec), [2]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }

    private static byte[] ArithmeticDictionaryBytes(List<Bm> symbols) =>
        Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [.. symbols.Select(_ => true)], 0, null, false, 0, null);

    [Theory]
    [InlineData(false, 0)]
    [InlineData(false, 1)]
    [InlineData(true, 0)]
    [InlineData(true, 1)]
    public void TextRegionRefinesSymbols(bool huffman, int refineTemplate)
    {
        var symbols = Symbols(8, 15);
        var refined = Bm.Text(symbols[3].Width + 2, symbols[3].Height + 1, 31);
        var refined2 = Bm.Text(symbols[1].Width, symbols[1].Height - 1, 32);
        var spec = new TextSpec
        {
            Huffman = huffman, Refine = true, RefineTemplate = refineTemplate, Width = 70, Height = 40, Symbols = symbols,
            Instances =
            [
                new Instance(0, 4, 4), new Instance(3, 20, 6, refined, 2, 1, 1, 0), new Instance(5, 40, 5), new Instance(1, 10, 25, refined2, 0, -1, -1, 1),
                new Instance(7, 50, 22),
            ],
            SymbolLengths = [.. symbols.Select(_ => 3)],
        };
        byte[] dictionary = Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [.. symbols.Select(_ => true)], 0, null, false, 0, null);
        byte[] text = huffman ? Jbig2TextEncode.HuffmanSegment(spec, 0) : Jbig2TextEncode.ArithmeticSegment(spec);
        var stream = Page(70, 40, Jbig2Segments.Segment(1, 0, dictionary), Jbig2Segments.Segment(2, 6, text, [1]));
        Assert.Equal(spec.Expected().Packed(), Decode(stream));
    }
}
