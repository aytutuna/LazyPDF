using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class ContentResourcesTests
{
    [Fact]
    public void InheritedResourcesAreCopiedOntoThePage()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(5, ContentTestPdf.Helvetica);
        var document = PdfDocument.Open(pdf.Finish());

        var resources = ContentResources.ForEdit(document, document.Pages[0]);
        string name = ContentResources.Add(document, resources, "ExtGState", new PdfDictionary(), "GS");
        Assert.Equal("GS1", name);
        Assert.Equal("GS2", ContentResources.Add(document, resources, "ExtGState", new PdfDictionary(), "GS"));
        Assert.NotNull(document.Pages[0].Resources!["Font"]);
        Assert.Null(document.Pages[1].Resources!["ExtGState"]);
        Assert.Same(resources, ContentResources.ForEdit(document, document.Pages[0]));
    }

    [Fact]
    public void NamesSkipThoseInUse()
    {
        var document = ContentTestPdf.Page("", "/Font <</F1 5 0 R /F2 5 0 R>>", ContentTestPdf.Helvetica);
        var resources = ContentResources.ForEdit(document, document.Pages[0]);
        Assert.Equal("F3", ContentResources.Add(document, resources, "Font", new PdfReference(5, 0), "F"));
    }

    [Fact]
    public void ARgbaImageDrawsAndReopensInPdfPig()
    {
        var document = PdfDocument.Open(TestPdf.Simple(1));
        var rgba = new byte[4 * 4 * 3];
        for (int i = 0; i < 12; i++)
        {
            rgba[4 * i] = (byte)(i * 20);
            rgba[4 * i + 3] = i == 0 ? (byte)128 : (byte)255;
        }
        var image = ContentImages.AddRgba(document, 4, 3, rgba);
        var page = document.Pages[0];
        string name = ContentResources.Add(document, ContentResources.ForEdit(document, page), "XObject", image, "Im");
        var content = new ContentWriter().Paint(name, new PdfMatrix(100, 0, 0, 75, 20, 30));
        page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), content.ToArray()));
        var file = document.SaveRewrite();

        using var pig = PigDocument.Open(file);
        var found = Assert.Single(pig.GetPage(1).GetImages());
        Assert.Equal((4, 3), (found.WidthInSamples, found.HeightInSamples));

        using var reopened = PdfDocument.Open(file);
        var r = ContentTestPdf.Run(reopened);
        var placed = Assert.Single(r.Images);
        Assert.Equal(new PdfRect(20, 30, 120, 105), placed.Bounds);
        Assert.NotNull(reopened.Resolve(placed.Dictionary["SMask"]));
    }

    [Fact]
    public void OpaqueImagesHaveNoMask()
    {
        var document = PdfDocument.Open(TestPdf.Simple(1));
        var reference = ContentImages.AddRgba(document, 1, 1, [1, 2, 3, 255]);
        Assert.Null(((PdfStream)document.Resolve(reference)!).Dictionary["SMask"]);
        Assert.Throws<ArgumentException>(() => ContentImages.AddRgba(document, 2, 2, [1, 2, 3]));
    }

    [Fact]
    public void JpegHeaderGivesSizeAndSpace()
    {
        var document = PdfDocument.Open(TestPdf.Simple(1));
        byte[] jpeg =
        [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x20, 0x03,
            1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9,
        ];
        var reference = ContentImages.AddJpeg(document, jpeg)!;
        var image = (PdfStream)document.Resolve(reference)!;
        Assert.Equal(32, document.Integer(image.Dictionary, "Width"));
        Assert.Equal(16, document.Integer(image.Dictionary, "Height"));
        Assert.Equal("DeviceRGB", document.Name(image.Dictionary, "ColorSpace"));
        Assert.Equal("DCTDecode", document.Name(image.Dictionary, "Filter"));
        Assert.Null(ContentImages.AddJpeg(document, [1, 2, 3, 4, 5]));
    }
}
