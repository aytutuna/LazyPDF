using Xunit;

namespace LazyPDF.Core.Tests;

// What the tools that need pixels make of a JBIG2 image now that the filter decodes it.
public class Jbig2CallerTests
{
    private const string Globals = "/DecodeParms <</JBIG2Globals 7 0 R>>";

    private static string Image(int width, int height, string extra = "") =>
        $"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode {extra}";

    private static byte[] White(int size) => Jbig2Segments.Generic(new Bm(size, size), 0, false);

    // A page of white made of an all white symbol from the globals, so that the image cannot be read without them.
    private static (byte[] Globals, byte[] Data) WhiteWithGlobals(int size)
    {
        var symbol = new[] { new Bm(size, size) };
        byte[] dictionary = Jbig2SymbolEncode.Arithmetic([], symbol.Select(s => new NewSymbol(s)).ToList(), [true], 0, null, false, 0, null);
        var spec = new TextSpec { Width = size, Height = size, Symbols = [.. symbol], Instances = [new Instance(0, 0, 0)] };
        return (Jbig2Segments.Segment(1, 0, dictionary, page: 0), Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(size, size)), Jbig2Segments.Segment(2, 6, Jbig2TextEncode.ArithmeticSegment(spec), [1])));
    }

    private const string Place = "q 160 0 0 160 100 100 cm /Im1 Do Q";

    // The top left 2 by 2 pixels of an 8 by 8 image placed as above.
    private static RedactionMark TopLeft() => RedactionMark.FromRect(0, new PdfRect(100, 220, 140, 260));

    private static IEnumerable<PdfStream> ImageStreams(PdfDocument document) =>
        document.ObjectNumbers.Select(document.Get).OfType<PdfStream>().Where(s => document.Name(s.Dictionary, "Subtype") == "Image");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RedactionZeroesTheMarkedPixelsOfAJbig2Image(bool globals)
    {
        var (shared, data) = WhiteWithGlobals(8);
        if (!globals) data = White(8);
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Image(8, 8, globals ? Globals : ""), data);
            if (globals) pdf.Stream(7, "", shared);
        });
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = Assert.Single(ImageStreams(output));
        Assert.Equal("FlateDecode", output.Name(image.Dictionary, "Filter"));
        Assert.False(image.Dictionary.ContainsKey("DecodeParms"));
        var expected = Enumerable.Repeat((byte)0xff, 8).ToArray();
        expected[0] = expected[1] = 0x3f;
        Assert.Equal(expected, output.Data(image));
        Assert.Equal(1, result.Report.Images);
        Assert.Equal(0, result.Report.Pages.Single().WholeImages);
        // Nothing of the coded picture or its globals is left to read the pixels from.
        Assert.DoesNotContain(output.ObjectNumbers.Select(output.Get).OfType<PdfStream>(), s => output.Name(s.Dictionary, "Filter") == "JBIG2Decode");
        Assert.False(RedactionKit.Holds(result.Bytes, "JBIG2Globals"));
    }

    [Fact]
    public void ARedactedJbig2PictureWithAnotherDepthThanOneBitIsRemovedWhole()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JBIG2Decode", White(8)));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    [Theory]
    [InlineData(12, 8)]
    [InlineData(5, 8)]
    [InlineData(8, 11)]
    [InlineData(8, 3)]
    [InlineData(13, 2)]
    public void APageOfAnotherSizeIsCutOrPaddedWithWhiteToTheImage(int width, int height)
    {
        var page = Bm.Text(8, 8, 17);
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, Image(width, height), Jbig2Segments.Generic(page, 0, false)));
        var found = Assert.Single(ImageExtractor.Extract(document, [0]));
        var (w, h, rgba) = ExportKit.PngDecode(found.Image.Data);
        Assert.Equal((width, height), (w, h));
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++) Assert.Equal(page[x, y] != 0 ? 0 : 255, rgba[(y * w + x) * 4]);
        }
    }

    [Fact]
    public void ARedactedPictureWhosePageIsNotItsSizeIsCutLikeAnyOther()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, Image(16, 16), White(8)));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(100, 100, 140, 140))]);
        using var output = RedactionKit.Open(result);
        var samples = output.Data(Assert.Single(ImageStreams(output)));
        Assert.Equal(32, samples.Length);
        Assert.Equal(0xff, samples[0]);
        Assert.Equal(0x0f, samples[28]);
    }

    // A page of which one region is drawn and another, a text region with no dictionary, is not.
    private static byte[] Partial()
    {
        var symbols = Jbig2SymbolTests.Symbols(2, 2);
        var spec = new TextSpec { Width = 8, Height = 8, Symbols = symbols, Instances = [new Instance(0, 1, 1)] };
        var e = new ArithEncoder();
        Jbig2Encode.Generic(e, new Bm(8, 8), 0, false);
        return Jbig2Segments.Cat(Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(8, 8)),
            Jbig2Segments.Segment(1, 6, Jbig2TextEncode.ArithmeticSegment(spec), [9]),
            Jbig2Segments.Segment(2, 38, Jbig2Segments.GenericData(new Bm(8, 8), e.Finish(), 0, false, false, null)));
    }

    [Fact]
    public void ARedactedPictureThatDecodedOnlyInPartIsRemovedWhole()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, Image(8, 8), Partial()));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    [Fact]
    public void ExportKeepsAPartialPictureAndMakeSmallerLeavesItAsStored()
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf => pdf.Stream(6, Image(8, 8), Partial()));
        Assert.Single(ImageExtractor.Extract(document, [0]));
        byte[] file = OptimizeKit.Build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 1 /Filter /JBIG2Decode", Partial()));
        using var source = PdfDocument.Open(file);
        var result = new PdfOptimizer(source).Run(OptimizeKit.Off with { ImageDpi = 8, ImageDpiAbove = 10, BilevelTolerance = 10 });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal("JBIG2Decode", after.Name(OptimizeKit.Image(after).Dictionary, "Filter"));
    }

    [Fact]
    public void MakeSmallerSkipsAnImageWhoseGlobalsAreBroken()
    {
        byte[] file = OptimizeKit.Build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 6 0 R>>",
                Jbig2Samples.WithGlobals().Data);
            pdf.Stream(6, "/Filter /FlateDecode", "not flate data at all");
        });
        foreach (var options in new[]
        {
            OptimizeKit.Off with { ImageDpi = 8, ImageDpiAbove = 10 },
            OptimizeKit.Off with { BilevelTolerance = 10 },
            OptimizeKit.Off with { Grayscale = true },
        })
        {
            using var source = PdfDocument.Open(file);
            var result = new PdfOptimizer(source).Run(options);
            using var after = PdfDocument.Open(result.Bytes);
            Assert.Equal("JBIG2Decode", after.Name(OptimizeKit.Image(after).Dictionary, "Filter"));
        }
    }

    [Fact]
    public void ImageExtractionReadsTheGlobals()
    {
        var sample = Jbig2Samples.WithGlobals();
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Image(64, 40, Globals), sample.Data);
            pdf.Stream(7, "", Jbig2Samples.Globals());
        });
        var found = Assert.Single(ImageExtractor.Extract(document, [0]));
        Assert.False(found.Image.IsJpeg);
        var (w, h, rgba) = ExportKit.PngDecode(found.Image.Data);
        Assert.Equal((64, 40), (w, h));
        for (int i = 0; i < w * h; i++)
        {
            byte gray = sample.Expected!.Px[i] != 0 ? (byte)0 : (byte)255;
            Assert.Equal(gray, rgba[i * 4]);
        }
    }

    [Fact]
    public void ObjectEditorExtractsAJbig2PictureAsPng()
    {
        var sample = Jbig2Samples.WithGlobals();
        var session = EditKit.Session("q 100 0 0 60 100 600 cm /Im1 Do Q", more: pdf =>
        {
            pdf.Stream(8, Image(64, 40, "/DecodeParms <</JBIG2Globals 9 0 R>>"), sample.Data);
            pdf.Stream(9, "", Jbig2Samples.Globals());
        }, resources: "/XObject <</Im1 8 0 R>>");
        var editor = new PageEditor(session, 0, new EditArialSource());
        var png = editor.ExtractImage(editor.Objects.OfType<ImageObject>().Single())!;
        Assert.Equal("png", png.Extension);
        var (w, h, rgba) = ExportKit.PngDecode(png.Data);
        Assert.Equal((64, 40), (w, h));
        Assert.Equal(sample.Expected!.Px[0] != 0 ? 0 : 255, rgba[0]);
    }

    [Fact]
    public void MakeSmallerLeavesABilevelJbig2ImageAndItsGlobalsAlone()
    {
        var sample = Jbig2Samples.WithGlobals();
        byte[] file = OptimizeKit.Build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, Image(64, 40, "/DecodeParms <</JBIG2Globals 6 0 R>>"), sample.Data);
            pdf.Stream(6, "", Jbig2Samples.Globals());
        });
        using var document = PdfDocument.Open(file);
        var options = OptimizeKit.Off with { ImageDpi = 72, ImageDpiAbove = 100, BilevelTolerance = 10 };
        var result = new PdfOptimizer(document).Run(options);
        using var after = PdfDocument.Open(result.Bytes);
        var image = OptimizeKit.Image(after);
        Assert.Equal("JBIG2Decode", after.Name(image.Dictionary, "Filter"));
        Assert.Equal(64, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(sample.Expected!.Packed(), after.Data(image));
        Assert.IsType<PdfReference>(((PdfDictionary)after.Resolve(image.Dictionary["DecodeParms"])!)["JBIG2Globals"]);
    }
}
