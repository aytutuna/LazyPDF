using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Chains of actions where something goes and something stays.
public class SanitizeRewireTests
{
    private static byte[] Linked(string catalogExtra, string annots, params (int Number, string Body)[] more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Annots [{annots}]>>");
        foreach (var (number, body) in more) pdf.Obj(number, body);
        return pdf.Finish();
    }

    private static SanitizeResult Run(byte[] file, SanitizeOptions options)
    {
        using var document = PdfDocument.Open(file);
        return new PdfSanitizer(document).Run(options);
    }

    [Fact]
    public async Task SurvivorsBehindAGoneActionThatLoopsBackStayBounded()
    {
        const int Count = 3000;
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 5 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(5, $"<</S /URI /URI (http://x.example) /Next [{string.Join(' ', Enumerable.Range(10, Count).Select(i => $"{i} 0 R"))}]>>");
        for (int i = 0; i < Count; i++) pdf.Obj(10 + i, "<</S /Named /N /NextPage /Next 5 0 R>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var sanitizer = new PdfSanitizer(document);

        await Task.Run(() => sanitizer.Scan()).WaitAsync(TimeSpan.FromSeconds(20));
        var result = await Task.Run(() => sanitizer.Run(new SanitizeOptions())).WaitAsync(TimeSpan.FromSeconds(20));

        Assert.True(result.Bytes.Length < 6_000_000);
        Assert.DoesNotContain("x.example", TestPdf.Text(result.Bytes));
        Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
    }

    [Fact]
    public void ActionsAfterAScriptInTheDocumentScriptTreeAreCountedAndFiltered()
    {
        byte[] file = Linked("/Names <</JavaScript <</Names [(a) 5 0 R]>>>>", "",
            (5, "<</S /JavaScript /JS (MARKERJS1) /Next 6 0 R>>"),
            (6, "<</S /Launch /F (MARKERLAUNCH.exe)>>"));
        using var document = PdfDocument.Open(file);
        Assert.Equal(1, SanitizeKit.Count(new PdfSanitizer(document).Scan(), SanitizeItem.LaunchActions));

        var kept = Run(file, new SanitizeOptions { JavaScript = false });
        Assert.True(OptimizeKit.Everywhere(kept.Bytes, "MARKERJS1"));
        Assert.False(OptimizeKit.Everywhere(kept.Bytes, "MARKERLAUNCH"));
        Assert.Equal(1, SanitizeKit.Count(kept.Removed, SanitizeItem.LaunchActions));
        Assert.Equal(1, SanitizeKit.Count(kept.Kept, SanitizeItem.JavaScript));
    }

    [Fact]
    public void ALaunchBehindAScriptTreeThatGoesIsReportedAsGone()
    {
        byte[] file = Linked("/Names <</JavaScript <</Names [(a) 5 0 R]>>>>", "",
            (5, "<</S /JavaScript /JS (MARKERJS1) /Next 6 0 R>>"),
            (6, "<</S /Launch /F (MARKERLAUNCH.exe)>>"));
        var result = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERLAUNCH"));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.LaunchActions));
        Assert.Equal(0, SanitizeKit.Count(result.Kept, SanitizeItem.LaunchActions));
    }

    [Fact]
    public void SurvivorsCarriedByACopyLeaveTheSharedActionAlone()
    {
        byte[] file = Linked("", "5 0 R 6 0 R",
            (5, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 7 0 R>>"),
            (6, "<</Type /Annot /Subtype /Link /Rect [20 0 29 9] /A 8 0 R>>"),
            (7, "<</S /URI /URI (http://x.example) /Next [8 0 R 9 0 R]>>"),
            (8, "<</S /Named /N /NextPage>>"),
            (9, "<</S /JavaScript /JS (MARKERJS1) /Next 8 0 R>>"));
        var result = Run(file, new SanitizeOptions { JavaScript = false });

        using var after = PdfDocument.Open(result.Bytes);
        var annots = after.Array(after.Pages[0].Dictionary, "Annots")!;
        var first = after.Dict((PdfDictionary)after.Resolve(annots.Items[0])!, "A")!;
        var second = after.Dict((PdfDictionary)after.Resolve(annots.Items[1])!, "A")!;
        Assert.False(second.ContainsKey("Next"));
        Assert.Equal("Named", after.Name(first, "S"));
        var next = after.Dict(first, "Next")!;
        Assert.Equal("JavaScript", after.Name(next, "S"));
        Assert.Equal("Named", after.Name(after.Dict(next, "Next")!, "S"));
    }

    [Fact]
    public void ARenditionScriptRemovedByTheOtherOptionIsNotReportedAsKept()
    {
        byte[] file = Linked("/OpenAction 5 0 R", "", (5, "<</S /Rendition /OP 0 /JS (MARKERJS1)>>"));
        var scriptsOff = Run(file, new SanitizeOptions { JavaScript = false });
        Assert.False(OptimizeKit.Everywhere(scriptsOff.Bytes, "MARKERJS1"));
        Assert.Equal(0, SanitizeKit.Count(scriptsOff.Kept, SanitizeItem.JavaScript));
        Assert.Equal(1, SanitizeKit.Count(scriptsOff.Removed, SanitizeItem.JavaScript));

        var launchOff = Run(file, new SanitizeOptions { LaunchActions = false });
        Assert.Equal(0, SanitizeKit.Count(launchOff.Kept, SanitizeItem.LaunchActions));
        Assert.Equal(1, SanitizeKit.Count(launchOff.Removed, SanitizeItem.LaunchActions));
    }
}
