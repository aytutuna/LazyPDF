using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeGrayCallerTests
{
    private const string Lab = "/L [/Lab <</WhitePoint [0.95 1 1.09]>>]";
    private const string Rgb = "/Cs0 [/ICCBased 6 0 R]";
    private const string FormEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]";

    private static readonly OptimizeOptions Gray = OptimizeKit.Off with { Grayscale = true };

    private static byte[] Run(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        return new PdfOptimizer(document).Run(Gray).Bytes;
    }

    private static IReadOnlyList<ContentOperation> Page(byte[] file, int index = 0)
    {
        using var document = PdfDocument.Open(file);
        return ContentParser.Parse(document.Pages[index].Contents());
    }

    // The form reached from the first page by these names, each looked up in the resources of the one before.
    private static IReadOnlyList<ContentOperation> Form(byte[] file, params string[] path)
    {
        using var document = PdfDocument.Open(file);
        var resources = document.Pages[0].Resources;
        PdfStream? form = null;
        foreach (string name in path)
        {
            form = (PdfStream)document.Resolve(document.Dict(resources, "XObject")![name])!;
            resources = document.Dict(form.Dictionary, "Resources");
        }
        return ContentParser.Parse(document.Data(form!));
    }

    private static string SpaceName(IEnumerable<ContentOperation> operations, string op) =>
        ((PdfName)operations.First(o => o.Operator == op).Operands[0]).Value;

    private static byte[] Pages(string contentsA, string contentsB, string resourcesA, string resourcesB, Action<TestPdf> more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents {contentsA} /Resources {resourcesA}>>");
        pdf.Obj(4, $"<</Type /Page /Parent 2 0 R /Contents {contentsB} /Resources {resourcesB}>>");
        more(pdf);
        return pdf.Finish();
    }

    [Fact]
    public void ASpotStrokeDoesNotKeepTheFillOperandsOfAForm()
    {
        const string resources = "/ColorSpace <</Sp [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>] " + Rgb + ">> /XObject <</Fm0 5 0 R>>";
        byte[] file = Run(OptimizeKit.Build("/Sp CS 1 SCN /Cs0 cs 1 0 0 sc /Fm0 Do", resources, pdf =>
        {
            pdf.Stream(5, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(6, "/N 3", "profile");
        }));

        Assert.Equal("DeviceGray", SpaceName(Page(file), "cs"));
        Assert.Single(Form(file, "Fm0").Single(o => o.Operator is "sc" or "g").Operands);
    }

    [Fact]
    public void ALabStrokeKeepsOnlyTheStrokeOperandsOfAForm()
    {
        byte[] file = Run(OptimizeKit.Build("/L CS /Cs0 cs /Fm0 Do", "/ColorSpace <<" + Lab + " " + Rgb + ">> /XObject <</Fm0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, FormEntries, "0.2 0.4 0.6 sc 0.2 0.4 0.6 SC 0 0 5 5 re B");
            pdf.Stream(6, "/N 3", "profile");
        }));

        var form = Form(file, "Fm0");
        Assert.Equal("L", SpaceName(Page(file), "CS"));
        Assert.Single(form.Single(o => o.Operator is "sc" or "g").Operands);
        Assert.Equal(3, form.Single(o => o.Operator == "SC").Operands.Count);
    }

    [Fact]
    public void AnRgbOperatorSetsTheSpaceTheColoursAfterItAreWrittenFor()
    {
        byte[] file = Run(OptimizeKit.Build("1 0 0 rg 0 0 5 5 re f 0 1 0 sc 5 5 5 5 re f", "/ColorSpace <<" + Lab + ">>"));

        var operations = Page(file);
        Assert.DoesNotContain(operations, o => o.Operator == "rg");
        Assert.All(operations.Where(o => o.Operator is "g" or "sc"), o => Assert.Single(o.Operands));
    }

    [Fact]
    public void AFormPaintedAfterAnRgbOperatorFollowsItWhateverTheFileHolds()
    {
        byte[] file = Run(OptimizeKit.Build("1 0 0 rg /Fm0 Do", "/ColorSpace <<" + Lab + ">> /XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")));

        Assert.Contains(Page(file), o => o.Operator == "g");
        Assert.Single(Form(file, "Fm0").Single(o => o.Operator is "sc" or "g").Operands);
    }

    [Fact]
    public void AFormCalledFromAFormGetsTheSpaceOfThePage()
    {
        byte[] file = Run(OptimizeKit.Build("/Cs0 cs /Fm0 Do", "/ColorSpace <<" + Lab + " " + Rgb + ">> /XObject <</Fm0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, FormEntries + " /Resources <</XObject <</Fm1 7 0 R>>>>", "/Fm1 Do");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(7, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f");
        }));

        Assert.Equal("DeviceGray", SpaceName(Page(file), "cs"));
        Assert.Single(Form(file, "Fm0", "Fm1").Single(o => o.Operator is "sc" or "g").Operands);
    }

    [Fact]
    public void AFormThatSetsItsOwnSpaceTellsTheFormItCallsWhateverTheObjectOrder()
    {
        byte[] file = Run(OptimizeKit.Build("/Fm0 Do", "/ColorSpace <<" + Lab + ">> /XObject <</Fm0 7 0 R>>", pdf =>
        {
            pdf.Stream(5, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(7, FormEntries + " /Resources <</ColorSpace <</Cs1 [/ICCBased 6 0 R]>> /XObject <</Fm1 5 0 R>>>>", "/Cs1 cs /Fm1 Do");
        }));

        Assert.Equal("DeviceGray", SpaceName(Form(file, "Fm0"), "cs"));
        Assert.Single(Form(file, "Fm0", "Fm1").Single(o => o.Operator is "sc" or "g").Operands);
    }

    [Fact]
    public void AFormPaintedUnderLabAndRgbKeepsItsOperandsAndSoDoesTheRgbCs()
    {
        const string resources = "<</ColorSpace <<" + Lab + " " + Rgb + ">> /XObject <</Fm0 5 0 R>>>>";
        byte[] file = Run(Pages("20 0 R", "21 0 R", resources, resources, pdf =>
        {
            pdf.Stream(5, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(20, "", "/L cs /Fm0 Do");
            pdf.Stream(21, "", "/Cs0 cs /Fm0 Do");
        }));

        Assert.Equal("L", SpaceName(Page(file, 0), "cs"));
        Assert.Equal("Cs0", SpaceName(Page(file, 1), "cs"));
        Assert.Equal(3, Form(file, "Fm0").Single(o => o.Operator == "sc").Operands.Count);
    }

    [Fact]
    public void ALabCallerReachedThroughAFormHoldsBackAnotherPagesRgbCs()
    {
        const string resources = "<</ColorSpace <<" + Lab + " " + Rgb + ">> /XObject <</Fm0 5 0 R>>>>";
        byte[] file = Run(Pages("20 0 R", "21 0 R", resources, resources, pdf =>
        {
            pdf.Stream(5, FormEntries + " /Resources <</XObject <</Fm1 7 0 R>>>>", "/Fm1 Do");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(7, FormEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(20, "", "/L cs /Fm0 Do");
            pdf.Stream(21, "", "/Cs0 cs /Fm0 Do");
        }));

        Assert.Equal("Cs0", SpaceName(Page(file, 1), "cs"));
        Assert.Equal(3, Form(file, "Fm0", "Fm1").Single(o => o.Operator == "sc").Operands.Count);
    }

    [Fact]
    public void AStreamSharedByPagesIsReadInEachPagesState()
    {
        byte[] file = Run(Pages("[20 0 R 21 0 R]", "[20 0 R 22 0 R]", "12 0 R", "12 0 R", pdf =>
        {
            pdf.Obj(12, "<</ColorSpace <<" + Rgb + ">>>>");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(20, "", "/Cs0 cs");
            pdf.Stream(21, "", "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(22, "", "0.3 0.2 0.1 sc 0 0 5 5 re f");
        }));

        foreach (int index in new[] { 0, 1 })
        {
            var operations = Page(file, index);
            Assert.Equal("DeviceGray", SpaceName(operations, "cs"));
            Assert.Single(operations.Single(o => o.Operator == "sc").Operands);
        }
    }

    [Fact]
    public void AStreamSharedByPagesWithDifferentSpacesIsLeftAlone()
    {
        byte[] file = Run(Pages("20 0 R", "20 0 R", "<</ColorSpace <<" + Rgb + ">>>>", "<</ColorSpace <<" + Rgb.Replace("[/ICCBased 6 0 R]", "[/Lab <</WhitePoint [0.95 1 1.09]>>]") + ">>>>", pdf =>
        {
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(20, "", "/Cs0 cs 0.2 0.4 0.6 sc 0 0 5 5 re f");
        }));

        var operations = Page(file, 1);
        Assert.Equal("Cs0", SpaceName(operations, "cs"));
        Assert.Equal(3, operations.Single(o => o.Operator == "sc").Operands.Count);
    }

    [Fact]
    public void AStreamLeftAloneHoldsBackTheCsThatSetsItsSpace()
    {
        byte[] file = Run(Pages("[20 0 R 22 0 R]", "[21 0 R 22 0 R]", "12 0 R", "12 0 R", pdf =>
        {
            pdf.Obj(12, "<</ColorSpace <<" + Rgb + ">>>>");
            pdf.Stream(6, "/N 3", "profile");
            pdf.Stream(20, "", "/Cs0 cs");
            pdf.Stream(21, "", "0 g");
            pdf.Stream(22, "", "0.2 0.4 0.6 sc 0 0 5 5 re f");
        }));

        var operations = Page(file, 0);
        Assert.Equal("Cs0", SpaceName(operations, "cs"));
        Assert.Equal(3, operations.Single(o => o.Operator == "sc").Operands.Count);
    }

    [Fact]
    public void AMaskSharedByAnImageThatStaysInColourKeepsItsMatteLength()
    {
        const string image = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 7 0 R ";
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do /Im1 Do Q", "/XObject <</Im0 5 0 R /Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(5, image + "/Filter /FlateDecode", TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 3)));
            pdf.Stream(6, image.Replace("8 /Height 8", "16 /Height 16") + "/Filter /DCTDecode", OptimizeKit.TinyJpeg);
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [1 0 0] /Filter /FlateDecode",
                TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 1)));
        });
        byte[] result = Run(file);

        using var after = PdfDocument.Open(result);
        Assert.Equal("DeviceRGB", after.Name(OptimizeKit.Image(after).Dictionary, "ColorSpace"));
        Assert.Equal(3, after.Array(((PdfStream)after.Get(7)!).Dictionary, "Matte")!.Items.Count);
    }
}
