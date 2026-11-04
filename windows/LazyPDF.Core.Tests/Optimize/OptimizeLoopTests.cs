using System.Diagnostics;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeLoopTests
{
    private static byte[] OnePage(string resources, string content, params (int N, string Body)[] more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Resources {resources} /Contents 4 0 R>>");
        pdf.Stream(4, "", content);
        foreach (var (n, body) in more) pdf.Obj(n, body);
        return pdf.Finish();
    }

    [Fact]
    public void A_chain_of_forms_without_resources_that_calls_itself_many_times_does_not_blow_up()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</F 5 0 R>>>> /Contents 4 0 R>>");
        pdf.Stream(4, "", "/F Do");
        pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", string.Concat(Enumerable.Repeat("/F Do ", 50)));
        using var document = PdfDocument.Open(pdf.Finish());

        var clock = Stopwatch.StartNew();
        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));

        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(20));
        Assert.NotEmpty(result.Bytes);
    }

    [Fact]
    public void Default_colour_spaces_stay_in_the_resources_though_no_operator_names_them()
    {
        byte[] file = OnePage("<</ColorSpace <</DefaultRGB [/ICCBased 5 0 R] /Unused /DeviceGray>>>>", "1 0 0 rg 0 0 10 10 re f",
            (5, "<</N 3 /Alternate /DeviceRGB>>"));
        using var document = PdfDocument.Open(file);

        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));

        using var reopened = PdfDocument.Open(result.Bytes);
        var spaces = reopened.Dict(reopened.Dict(reopened.Pages[0].Dictionary, "Resources"), "ColorSpace");
        Assert.NotNull(spaces);
        Assert.True(spaces.ContainsKey("DefaultRGB"));
        Assert.False(spaces.ContainsKey("Unused"));
    }
}
