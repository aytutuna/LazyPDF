using System.Diagnostics;
using Xunit;

namespace LazyPDF.Core.Tests;

// Some of these run the decoder for seconds on purpose; alone, they do not slow down the timing tests of other classes.
[CollectionDefinition("Jbig2 limits", DisableParallelization = true)]
public sealed class Jbig2LimitsCollection;

[Collection("Jbig2 limits")]
public class Jbig2FilterTests
{
    private static byte[] Decode(byte[] stream, PdfObject? parameters = null, long maxSize = PdfFilters.DefaultMaxSize) =>
        PdfFilters.Decode(stream, new PdfName("JBIG2Decode"), parameters, maxSize);

    private static PdfDictionary WithGlobals(byte[] globals)
    {
        var parameters = new PdfDictionary();
        parameters["JBIG2Globals"] = new PdfStream(new PdfDictionary(), globals);
        return parameters;
    }

    [Fact]
    public void GlobalsComeFirstAndTheImageUsesTheirSymbols()
    {
        var sample = Jbig2Samples.WithGlobals();
        Assert.Equal(sample.Expected!.Packed(), Decode(sample.Data, WithGlobals(Jbig2Samples.Globals())));
        // Without them the text region has nothing to draw.
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Decode(sample.Data)).Problem);
    }

    [Fact]
    public void ImageStreamInAFileReadsItsGlobalsThroughTheDocument()
    {
        var sample = Jbig2Samples.WithGlobals();
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "", Jbig2Samples.Globals());
        pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", sample.Data);
        var document = PdfDocument.Open(pdf.Finish());
        Assert.Equal(sample.Expected!.Packed(), document.Data((PdfStream)document.Get(8)!));
    }

    [Fact]
    public void GlobalsMayBeFlateCodedAndTheStageMayFollowAnotherFilter()
    {
        var sample = Jbig2Samples.WithGlobals();
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "/Filter /FlateDecode", TestPdf.Deflate(Jbig2Samples.Globals()));
        pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter [/FlateDecode /JBIG2Decode] /DecodeParms [null <</JBIG2Globals 7 0 R>>]",
            TestPdf.Deflate(sample.Data));
        var document = PdfDocument.Open(pdf.Finish());
        Assert.Equal(sample.Expected!.Packed(), document.Data((PdfStream)document.Get(8)!));
    }

    [Fact]
    public void DecodeToCodecNoLongerStopsAtJbig2()
    {
        var sample = Jbig2Samples.WithGlobals();
        var result = PdfFilters.DecodeToCodec(sample.Data, new PdfName("JBIG2Decode"), WithGlobals(Jbig2Samples.Globals()));
        Assert.Null(result.Codec);
        Assert.Equal(sample.Expected!.Packed(), result.Data);
        var kept = PdfFilters.DecodeToCodec(sample.Data, new PdfName("JBIG2Decode"), null, PdfFilters.DefaultMaxSize, keepJbig2: true);
        Assert.Equal("JBIG2Decode", kept.Codec);
        Assert.Same(sample.Data, kept.Data);
    }

    [Fact]
    public void OutputIsBoundedByTheSizeLimit()
    {
        var bm = Bm.Text(80, 80, 3);
        var e = Assert.Throws<PdfReadException>(() => Decode(Jbig2Segments.Generic(bm, 0, false), null, 500));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
        Assert.Equal(bm.Packed(), Decode(Jbig2Segments.Generic(bm, 0, false), null, 800));
    }

    [Fact]
    public void PageOverTheSizeLimitIsRefusedBeforeItIsMade()
    {
        // 30000 by 30000 is 112 MB of pixels, inside the pixel limit, but its rows are 113 MB: past a limit of a megabyte.
        var e = Assert.Throws<PdfReadException>(() => Decode(Page(30000, 30000), null, 1 << 20));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
        Assert.Equal(FilterBuffer.TooBig().Message, e.Message);
    }

    private static void Unsupported(byte[] stream) =>
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => Decode(stream)).Problem);

    private static void Damaged(byte[] stream) =>
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Decode(stream)).Problem);

    private static byte[] Page(int width, int height, params byte[][] segments) =>
        Jbig2Segments.Cat([Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(width, height)), .. segments]);

    [Fact]
    public void PagesAndRegionsOverThePixelLimitAreRefusedBeforeAnythingIsMade()
    {
        Unsupported(Page(int.MaxValue, 5));
        Unsupported(Page(20000, 20000));
        Unsupported(Page(0x7fffffff, 0x7fffffff));
        // A region far bigger than the page, in a stream that is a few bytes long.
        var bm = new Bm(4, 4);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        byte[] data = Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null);
        Array.Copy(Jbig2Segments.U32(100000), 0, data, 0, 4);
        Array.Copy(Jbig2Segments.U32(100000), 0, data, 4, 4);
        Unsupported(Page(10, 10, Jbig2Segments.Segment(1, 38, data)));
    }

    [Fact]
    public void ManyMediumRegionsRunOutOfTheMemoryBudget()
    {
        // Each region is within the limit and the stream is small, but together they ask for more than a decode may make.
        // MMR data that ends at once leaves the rest of the region white, so every region is quick.
        var bm = new Bm(4, 4);
        byte[] data = Jbig2Segments.GenericData(bm, [], 0, true, false, null);
        Array.Copy(Jbig2Segments.U32(11000), 0, data, 0, 4);
        Array.Copy(Jbig2Segments.U32(11000), 0, data, 4, 4);
        var segments = new List<byte[]> { Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(8, 8)) };
        for (int i = 1; i <= 8; i++) segments.Add(Jbig2Segments.Segment(i, 38, data));
        Unsupported(Jbig2Segments.Cat([.. segments]));
    }

    [Fact]
    public void StripedPageThatReachesFarDownIsRefused()
    {
        var bm = new Bm(10, 4);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        byte[] data = Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null, 0, 0x7ffffff0);
        Unsupported(Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(10, -1)), Jbig2Segments.Segment(1, 38, data)));
        Unsupported(Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(10, -1)), Jbig2Segments.Segment(1, 50, Jbig2Segments.U32(0x7ffffff0))));
    }

    [Fact]
    public void SymbolCountsAndInstanceCountsAreCapped()
    {
        // A dictionary that says it holds a billion symbols.
        byte[] dictionary = Jbig2Segments.Cat(Jbig2Segments.U16(0), Jbig2Segments.At([3, -1, -3, -1, 2, -2, -2, -2]), Jbig2Segments.U32(1000000000), Jbig2Segments.U32(1000000000), [0xff, 0xac]);
        Damaged(Page(10, 10, Jbig2Segments.Segment(1, 0, dictionary)));

        // A text region with 4 billion instances.
        var symbols = Jbig2SymbolTests.Symbols(4, 1);
        var spec = new TextSpec { Width = 20, Height = 20, Symbols = symbols, Instances = [new Instance(0, 1, 1)] };
        byte[] text = Jbig2TextEncode.ArithmeticSegment(spec);
        Array.Copy(Jbig2Segments.U32(0xffffffffL), 0, text, 17 + 2, 4);
        byte[] dict = Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [true, true, true, true], 0, null, false, 0, null);
        Damaged(Page(20, 20, Jbig2Segments.Segment(1, 0, dict), Jbig2Segments.Segment(2, 6, text, [1])));
    }

    [Fact]
    public void ExportRunsBeyondTheSymbolsAreDamage()
    {
        var symbols = Jbig2SymbolTests.Symbols(3, 2);
        var e = new ArithEncoder();
        int height = 0;
        foreach (var s in symbols.GroupBy(b => b.Height))
        {
            e.Integer(ArithEncoder.Iadh, s.Key - height);
            height = s.Key;
            int width = 0;
            foreach (var b in s)
            {
                e.Integer(ArithEncoder.Iadw, b.Width - width);
                width = b.Width;
                Jbig2Encode.Generic(e, b, 0, false);
            }
            e.Integer(ArithEncoder.Iadw, null);
        }
        e.Integer(ArithEncoder.Iaex, 0);
        e.Integer(ArithEncoder.Iaex, 1000000);
        byte[] data = Jbig2Segments.Cat(Jbig2Segments.U16(0), Jbig2Segments.At(Jbig2Encode.DefaultAt(0)), Jbig2Segments.U32(3), Jbig2Segments.U32(3), e.Finish());
        Damaged(Page(10, 10, Jbig2Segments.Segment(1, 0, data)));
    }

    [Fact]
    public void ImpossibleSegmentHeadersAreDamage()
    {
        // A long form count of 0x1FFFFFFF referred segments in a header that ends there.
        Damaged(Jbig2Segments.Cat(Jbig2Segments.U32(1), [0x28], Jbig2Segments.U32(0xffffffffL)));
        // A short form count of 5, which only the long form may have.
        Damaged(Jbig2Segments.Cat(Jbig2Segments.U32(1), [0x28, 0xa0], [1, 2, 3, 4, 5], [1], Jbig2Segments.U32(0)));
        // No length on a segment that must have one.
        Damaged(Jbig2Segments.Cat(Jbig2Segments.U32(1), [0x30, 0x00, 0x01], Jbig2Segments.U32(0xffffffffL)));
        // A region before the page, and a stream without a page.
        Damaged(Jbig2Segments.Segment(1, 38, Jbig2Segments.GenericData(new Bm(2, 2), [0xff, 0xac], 0, false, false, null)));
        Damaged([]);
    }

    [Fact]
    public void SegmentsThatCannotBeDecodedAreLeftOutAndTheRestIsKept()
    {
        var bm = Bm.Text(30, 20, 7);
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, bm, 0, false);
        // A text region that refers to a symbol dictionary that is not there, between two good segments.
        var symbols = Jbig2SymbolTests.Symbols(2, 2);
        var spec = new TextSpec { Width = 30, Height = 20, Symbols = symbols, Instances = [new Instance(0, 2, 2)] };
        var stream = Page(30, 20,
            Jbig2Segments.Segment(1, 6, Jbig2TextEncode.ArithmeticSegment(spec), [9]),
            Jbig2Segments.Segment(2, 38, Jbig2Segments.GenericData(bm, e.Finish(), 0, false, false, null)));
        Assert.Equal(bm.Packed(), Decode(stream));
    }

    [Fact]
    public void CutAndDamagedStreamsGiveAnErrorOrWhatDecodedAndNeverHang()
    {
        var time = Stopwatch.StartNew();
        var samples = Jbig2Samples.All().ToList();
        var globals = WithGlobals(Jbig2Samples.Globals());
        foreach (var sample in samples)
        {
            for (int length = 0; length < sample.Data.Length; length += Math.Max(1, sample.Data.Length / 60))
            {
                Try(sample.Data[..length], globals);
            }
        }
        var random = new Random(77);
        for (int round = 0; round < 25; round++)
        {
            foreach (var sample in samples)
            {
                var data = (byte[])sample.Data.Clone();
                for (int flips = random.Next(1, 4); flips > 0; flips--) data[random.Next(data.Length)] ^= (byte)(1 << random.Next(8));
                Try(data, globals);
            }
        }
        Assert.True(time.Elapsed < TimeSpan.FromSeconds(60), time.Elapsed.ToString());
    }

    private static void Try(byte[] data, PdfDictionary globals)
    {
        try
        {
            Decode(data, globals);
        }
        catch (PdfReadException)
        {
        }
    }

    [Fact]
    public void HuffmanTablesThatDoNotFitAreDamage()
    {
        // Prefix lengths of 1 for three values cannot all be codes.
        Assert.Throws<PdfReadException>(() => new Jbig2Huffman([(0, 1, 0, 0), (1, 1, 0, 0), (2, 1, 0, 0)]));
        Assert.Throws<PdfReadException>(() => new Jbig2Huffman([(0, 40, 0, 0)]));
        // A table segment of 32 bit ranges that never reaches its upper end ends with the data.
        byte[] segment = [0, 0x80, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0x12, 0x34];
        Assert.Throws<PdfReadException>(() => Jbig2Huffman.Custom(segment, 0, segment.Length));
    }

    [Fact]
    public void ARunOfInstancesPastTheEndOfTheDataStillEnds()
    {
        // A text region of the most instances there may be, coded in a few bytes: the data runs out and the decoder keeps going on the ones it is fed.
        var symbols = Jbig2SymbolTests.Symbols(2, 5);
        var spec = new TextSpec { Width = 10, Height = 10, Symbols = symbols, Instances = [new Instance(0, 1, 1)] };
        byte[] text = Jbig2TextEncode.ArithmeticSegment(spec);
        Array.Copy(Jbig2Segments.U32(Jbig2Text.MaxInstances), 0, text, 17 + 2, 4);
        byte[] dict = Jbig2SymbolEncode.Arithmetic([], symbols.Select(s => new NewSymbol(s)).ToList(), [true, true], 0, null, false, 0, null);
        var time = Stopwatch.StartNew();
        Try(Page(10, 10, Jbig2Segments.Segment(1, 0, dict), Jbig2Segments.Segment(2, 6, text, [1])), new PdfDictionary());
        Assert.True(time.Elapsed < TimeSpan.FromSeconds(30), time.Elapsed.ToString());
    }
}
