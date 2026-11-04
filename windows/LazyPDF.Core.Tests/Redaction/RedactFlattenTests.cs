using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A page the redaction cannot follow becomes one picture: drawn from the file as it stands, the marks filled in the pixels.
public class RedactFlattenTests
{
    private const string Loop = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET /Fm Do";
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    // A form that paints itself is read differently from how a viewer draws it, which is what makes a page not understood.
    private static PdfDocument Looping(string extra = "", string page = Loop) =>
        RedactionKit.Page(page, "/XObject <</Fm 6 0 R>>" + extra, pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do"));

    // Samples of the picture of the page: RGB, top row first.
    private static (byte[] Samples, int Width, int Height) Picture(PdfDocument output, int page = 0)
    {
        var image = Assert.Single(RedactionKit.Images(output, page));
        Assert.Equal("DeviceRGB", output.Name(image.Stream!.Dictionary, "ColorSpace"));
        return (output.Data(image.Stream!), image.Width, image.Height);
    }

    private static byte[] Pixel((byte[] Samples, int Width, int Height) picture, double column, double row)
    {
        int i = ((int)row * picture.Width + (int)column) * 3;
        return picture.Samples[i..(i + 3)];
    }

    [Fact]
    public void MarkIsFilledInThePixelsAndTheRestIsTheRenderedPage()
    {
        using var document = Looping();
        var result = RedactionKit.AssertFlattened(document, Near, "ZQXCYCLE");
        using var output = RedactionKit.Reopen(result.Bytes);
        var picture = Picture(output);
        double scale = picture.Width / 600.0;
        Assert.Equal(new byte[] { 0, 0, 0 }, Pixel(picture, 145 * scale, (800 - 105) * scale));
        Assert.NotEqual(new byte[] { 0, 0, 0 }, Pixel(picture, 400 * scale, 400 * scale));
    }

    [Fact]
    public void MarkFillColourIsUsedInThePixels()
    {
        using var document = Looping();
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near, [1, 0, 0])]);
        using var output = RedactionKit.Reopen(result.Bytes);
        var picture = Picture(output);
        double scale = picture.Width / 600.0;
        Assert.Equal(new byte[] { 255, 0, 0 }, Pixel(picture, 145 * scale, (800 - 105) * scale));
    }

    [Fact]
    public void PageIsDrawnAtTheDpiOfTheOptionsAndAt200ByDefault()
    {
        using var document = Looping();
        var renderer = new RedactFakeRenderer(document);
        new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)], new RedactionOptions { Renderer = renderer });
        new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)], new RedactionOptions { Renderer = renderer, FlattenDpi = 36 });
        Assert.Equal([200, 36], renderer.Dpis);
    }

    [Fact]
    public void FlattenMarkedPagesDrawsAPageThatWasUnderstood()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET");
        var marks = RedactionKit.MarksOf(document, 0, "ZQXMARKER");
        Assert.Empty(new PdfRedactor(document).Apply(marks, RedactionKit.Drawing(document)).Report.Flattened);
        var result = new PdfRedactor(document).Apply(marks, RedactionKit.Drawing(document, new RedactionOptions { FlattenMarkedPages = true }));
        Assert.Equal([0], result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMARKER"));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.DoesNotContain("Tj", RedactionKit.Latin(output));
    }

    [Fact]
    public void FlattenMarkedPagesWithoutARendererIsRefused()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET");
        var marks = RedactionKit.MarksOf(document, 0, "ZQXMARKER");
        var error = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply(marks, new RedactionOptions { FlattenMarkedPages = true }));
        Assert.Equal(RedactionText.NeedsPicture(0), error.Message);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    [InlineData(5000)]
    public void DpiOutOfRangeIsRefused(double dpi)
    {
        using var document = Looping();
        var options = new RedactionOptions { Renderer = new RedactFakeRenderer(document), FlattenDpi = dpi };
        Assert.Throws<ArgumentOutOfRangeException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)], options));
    }

    [Fact]
    public void RotatedPageKeepsItsBoxesAndTurnAndTheMarkStaysWhereItWas()
    {
        using var document = Looping(page: "/Fm Do BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET");
        var page = document.Pages[0].Dictionary;
        page["Rotate"] = new PdfNumber(90);
        page["CropBox"] = new PdfRect(20, 30, 520, 700).ToArray();
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);
        using var output = RedactionKit.Reopen(result.Bytes);
        var flat = output.Pages[0];
        Assert.Equal(90, flat.Rotate);
        Assert.Equal(new PdfRect(20, 30, 520, 700), flat.CropBox);
        Assert.Equal(document.Pages[0].MediaBox, flat.MediaBox);
        var picture = Picture(output);
        var geometry = new PageGeometry(flat);
        var (x, y) = geometry.ToDisplay(145, 105);
        Assert.Equal(new byte[] { 0, 0, 0 }, Pixel(picture, x * picture.Width / geometry.Width, y * picture.Height / geometry.Height));
    }

    [Fact]
    public void OldContentResourcesAndPageExtrasAreGone()
    {
        using var document = Looping("/Properties <</P0 <</Alt (ZQXPROPS)>>>>");
        var page = document.Pages[0].Dictionary;
        page["PieceInfo"] = new PdfDictionary { ["App"] = PdfText.ToObject("ZQXPIECE") };
        page["Group"] = new PdfDictionary { ["S"] = new PdfName("Transparency") };
        page["Foo"] = PdfText.ToObject("ZQXEXTRA");
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);
        Assert.Contains(0, result.Report.Flattened);
        foreach (string word in new[] { "ZQXCYCLE", "ZQXPROPS", "ZQXPIECE", "ZQXEXTRA" }) Assert.False(RedactionKit.Holds(result.Bytes, word), word);
        using var output = RedactionKit.Reopen(result.Bytes);
        var flat = output.Pages[0].Dictionary;
        Assert.Equal(["Contents", "Parent", "Resources", "Type"], flat.Entries.Select(e => e.Key).Where(k => k != "MediaBox").Order());
    }

    [Fact]
    public void AnnotationsAndFieldsLeaveAPageThatBecamePicture()
    {
        using var document = Looping();
        new PdfAnnotationWriter(document).AddLink(document.Pages[0], new PdfRect(300, 300, 400, 320), new UriAction("https://example.com/ZQXLINK"));
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(300, 400, 400, 420)) { Value = "ZQXVALUE" });
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(PdfAnnotations.Read(output, output.Pages[0]));
        Assert.Null(output.Dict(output.Catalog, "AcroForm"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXLINK"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXVALUE"));
        Assert.Equal(1, result.Report.Fields);
    }

    [Fact]
    public void OverlayTextIsDrawnAsTextOnTheFlattenedPage()
    {
        using var document = Looping();
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near, null, "X-1")]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("X-1", RedactionKit.Text(output));
    }

    [Fact]
    public void WithoutARendererTheCallRefusesAndNamesThePage()
    {
        using var document = Looping();
        var error = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]));
        Assert.Equal(RedactionText.NeedsPicture(0), error.Message);
        Assert.Contains("Page 1", error.Message);
    }

    [Fact]
    public void RefusalNamesTheFirstPageThatNeedsAPicture()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 8 0 R] /Count 3 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>");
        pdf.Obj(8, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>");
        pdf.Stream(5, "", "BT /F1 12 Tf 100 100 Td (ZQXFINE) Tj ET");
        pdf.Stream(6, "", Loop);
        pdf.Obj(7, RedactionKit.Helvetica);
        pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", "/Fm Do");
        using var document = PdfDocument.Open(pdf.Finish());
        var marks = new[] { 0, 1, 2 }.Select(i => RedactionMark.FromRect(i, Near)).ToList();
        var error = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply(marks));
        Assert.Equal(RedactionText.NeedsPicture(1), error.Message);

        var result = RedactionKit.Apply(document, marks);
        Assert.Equal([1, 2], result.Report.Flattened);
        using var output = RedactionKit.Open(result);
        Assert.Equal("", RedactionKit.Text(output, 0));
        Assert.Single(RedactionKit.Images(output, 1));
    }

    [Fact]
    public void RendererThatCannotDrawThePageRefuses()
    {
        using var document = Looping();
        var options = new RedactionOptions { Renderer = new NoRenderer() };
        var error = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)], options));
        Assert.Equal(RedactionText.NotDrawn(0), error.Message);
    }

    [Fact]
    public void ReportSaysInPlainWordsWhichPagesAreNoLongerText()
    {
        using var document = Looping();
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);
        Assert.Equal([0], result.Report.Flattened);
        Assert.Contains("Page 1 was turned into a picture. Its text can no longer be selected.", result.Report.ToString());
        Assert.DoesNotContain("Nothing was under the marks", result.Report.ToString());
    }

    [Fact]
    public void OrdinaryPageIsRedactedAsTextAndNeverDrawn()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE kept) Tj ET");
        var renderer = new RedactFakeRenderer(document);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXCYCLE"), new RedactionOptions { Renderer = renderer });
        Assert.Empty(renderer.Drawn);
        Assert.Empty(result.Report.Flattened);
        using var output = RedactionKit.Open(result);
        Assert.Equal("kept", RedactionKit.Text(output).Trim());
    }

    [Fact]
    public void PageWithoutMarksIsNotDrawn()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Stream(5, "", Loop);
        pdf.Stream(6, "", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET");
        pdf.Obj(7, RedactionKit.Helvetica);
        pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", "/Fm Do");
        using var document = PdfDocument.Open(pdf.Finish());
        var renderer = new RedactFakeRenderer(document);
        var marks = RedactionKit.MarksOf(document, 1, "ZQXCYCLE");
        var result = new PdfRedactor(document).Apply(marks, new RedactionOptions { Renderer = renderer });
        Assert.Empty(renderer.Drawn);
        Assert.Empty(result.Report.Flattened);
    }

    private sealed class NoRenderer : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi) => null;
    }
}
