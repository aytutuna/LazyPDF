using Xunit;

namespace LazyPDF.Core.Tests;

public class ResizePatternTests
{
    // Two pages that share one set of resources with a tiling pattern and a shading pattern.
    private static PdfDocument TwoPages()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R 11 0 R] /Count 2 /MediaBox [0 0 200 300]>>");
        pdf.Obj(5, "<</Pattern <</P1 6 0 R /P2 7 0 R>>>>");
        pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Matrix [1 0 0 1 10 20] /Resources <<>>", "1 0 0 rg 0 0 5 5 re f");
        pdf.Obj(7, "<</Type /Pattern /PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1>>>>>>");
        for (int i = 0; i < 2; i++)
        {
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {20 + i} 0 R /Resources 5 0 R>>");
            pdf.Stream(20 + i, "", "/Pattern cs /P1 scn 20 20 100 100 re f /P2 scn 20 150 100 100 re f");
        }
        return PdfDocument.Open(pdf.Finish());
    }

    private static double[] Matrix(PdfDocument document, int page, string name)
    {
        var pattern = document.Resolve(document.Dict(document.Pages[page].Resources, "Pattern")![name]);
        var dictionary = pattern is PdfStream stream ? stream.Dictionary : (PdfDictionary)pattern!;
        return [.. document.Array(dictionary, "Matrix")?.Items.Select(i => ((PdfNumber)i).Value) ?? [1, 0, 0, 1, 0, 0]];
    }

    [Fact]
    public void ScalingAPageMovesTheMatricesOfItsPatterns()
    {
        var document = TwoPages();
        PageOperations.Resize(document, [0], 400, 600, ResizeMode.ScaleContent);
        var bytes = document.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);

        var again = PdfDocument.Open(bytes);
        Assert.Equal([2, 0, 0, 2, 20, 40], Matrix(again, 0, "P1"));
        Assert.Equal([2, 0, 0, 2, 0, 0], Matrix(again, 0, "P2"));
        Assert.Equal(400, again.Pages[0].MediaBox.Width);
    }

    [Fact]
    public void PagesThatShareThePatternsKeepTheirOwn()
    {
        var document = TwoPages();
        PageOperations.Resize(document, [0], 400, 600, ResizeMode.ScaleContent);
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal([1, 0, 0, 1, 10, 20], Matrix(again, 1, "P1"));
        Assert.Equal([1, 0, 0, 1, 0, 0], Matrix(again, 1, "P2"));
        Assert.Equal(200, again.Pages[1].MediaBox.Width);
    }

    [Fact]
    public void AnOffCentreFitAddsItsShiftToThePatternToo()
    {
        var document = TwoPages();
        PageOperations.Resize(document, [0, 1], 400, 300, ResizeMode.ScaleContent);
        var again = PdfDocument.Open(document.SaveRewrite());
        // 200 by 300 into 400 by 300: scale 1, centred, 100 across.
        Assert.Equal([1, 0, 0, 1, 110, 20], Matrix(again, 0, "P1"));
        Assert.Equal([1, 0, 0, 1, 110, 20], Matrix(again, 1, "P1"));
    }
}
