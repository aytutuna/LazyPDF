using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StampReviewTests
{
    [Fact]
    public void RunsWithTheSameIdFromTwoFilesStayApartInAMerge()
    {
        var a = StampKit.Doc(1);
        var b = StampKit.Doc(1);
        new PdfStamper(a).AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        new PdfStamper(b).AddWatermark(new WatermarkSpec { Text = "CONFIDENTIAL" });

        var merged = PageAssembly.Merge([new MergeSource(a), new MergeSource(b)]);

        var stamper = new PdfStamper(merged);
        var runs = stamper.List();
        Assert.Equal(2, runs.Count);
        var confidential = runs.Single(r => r.Label == "CONFIDENTIAL");
        Assert.Equal(1, stamper.Remove(confidential.Id));
        Assert.Equal("DRAFT", Assert.Single(stamper.List()).Label);
        using var reopened = PdfDocument.Open(merged.SaveRewrite());
        Assert.Equal("DRAFT", StampKit.Text(StampKit.Glyphs(reopened, 0)));
        Assert.Empty(StampKit.Glyphs(reopened, 1));
    }

    [Fact]
    public void ARunSharedByADuplicatedPageIsRemovedFromBoth()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        PageOperations.Duplicate(document, [0]);

        Assert.Equal(2, stamper.Remove(run.Id));
        Assert.Empty(stamper.List());
    }

    [Fact]
    public void AFailedUpdateKeepsTheOldRun()
    {
        var document = StampKit.Doc(2);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "KEEP" });

        Assert.Throws<ArgumentException>(() => stamper.Update(run.Id, new WatermarkSpec()));

        var info = Assert.Single(stamper.List());
        Assert.Equal("KEEP", info.Label);
        Assert.Equal(2, info.Pages.Count);
    }

    [Fact]
    public void ABackgroundArtifactHasABox()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.9) });
        string content = Encoding.Latin1.GetString(document.Pages[0].Contents());
        Assert.Contains("/BBox", content);
    }
}
