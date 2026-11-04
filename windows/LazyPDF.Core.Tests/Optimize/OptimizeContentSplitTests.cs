using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeContentSplitTests
{
    private static PdfDocument Run(byte[] file, OptimizeOptions options)
    {
        using var document = PdfDocument.Open(file);
        return PdfDocument.Open(new PdfOptimizer(document).Run(options).Bytes);
    }

    [Fact]
    public void An_operator_in_the_next_content_stream_still_names_its_operand()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] /Resources <</XObject <</Im0 6 0 R>>>>>>");
        pdf.Stream(4, "", "q 10 0 0 10 0 0 cm /Im0");
        pdf.Stream(5, "", "Do Q");
        pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "\0");

        using var after = Run(pdf.Finish(), OptimizeKit.Off with { PruneResources = true });

        Assert.True(after.Dict(after.Pages[0].Resources, "XObject")!.ContainsKey("Im0"));
    }

    [Fact]
    public void The_base_space_of_an_inline_indexed_image_is_kept()
    {
        const string content = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /BPC 8 /CS [/I /Cs0 1 <000000ffffff>] ID \0 EI Q";
        byte[] file = OptimizeKit.Build(content, "/ColorSpace <</Cs0 /DeviceRGB /Unused /DeviceGray>>");

        using var after = Run(file, OptimizeKit.Off with { PruneResources = true });

        var spaces = after.Dict(after.Pages[0].Resources, "ColorSpace")!;
        Assert.True(spaces.ContainsKey("Cs0"));
        Assert.False(spaces.ContainsKey("Unused"));
    }

    [Fact]
    public void A_colour_set_in_a_space_that_cannot_be_looked_up_keeps_all_its_operands()
    {
        byte[] file = OptimizeKit.Build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "/Cs1 cs 0.5 0.5 0.5 sc 0 0 5 5 re f"));

        using var after = Run(file, OptimizeKit.Off with { Grayscale = true });

        var form = (PdfStream)after.Resolve(after.Dict(after.Pages[0].Resources, "XObject")!["Fm0"])!;
        var set = ContentParser.Parse(after.Data(form)).Single(o => o.Operator == "sc");
        Assert.Equal(3, set.Operands.Count);
    }

    [Fact]
    public void A_matte_follows_the_image_to_gray()
    {
        const string dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode";
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, dictionary + " /ColorSpace /DeviceRGB /SMask 6 0 R", TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 3)));
            pdf.Stream(6, dictionary + " /ColorSpace /DeviceGray /Matte [1 0 0]", TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 1)));
        });

        using var after = Run(file, OptimizeKit.Off with { Grayscale = true });

        var image = OptimizeKit.Image(after);
        Assert.Equal("DeviceGray", after.Name(image.Dictionary, "ColorSpace"));
        var matte = after.Array(after.Stream(image.Dictionary, "SMask")!.Dictionary, "Matte")!;
        var value = Assert.IsType<PdfNumber>(Assert.Single(matte.Items));
        Assert.Equal(0.299, value.Value, 3);
    }
}
