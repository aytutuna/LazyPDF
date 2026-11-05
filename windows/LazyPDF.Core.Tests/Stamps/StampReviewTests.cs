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
    public void TwoRunsFromEachOfTwoFilesStayApartInAMerge()
    {
        var a = StampKit.Doc(1);
        var b = StampKit.Doc(1);
        foreach (var (document, first, second) in new[] { (a, "AONE", "ATWO"), (b, "BONE", "BTWO") })
        {
            new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = first });
            new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = second });
        }

        var merged = PageAssembly.Merge([new MergeSource(a), new MergeSource(b)]);

        var stamper = new PdfStamper(merged);
        var runs = stamper.List();
        Assert.Equal(["AONE", "ATWO", "BONE", "BTWO"], runs.Select(r => r.Label).Order());
        Assert.Equal(4, runs.Select(r => r.Id).Distinct().Count());
        Assert.Equal("BONEBTWO", StampKit.Text(StampKit.Glyphs(merged, 1)));
        string content = StampKit.Latin(merged, 1);
        var fonts = merged.Dict(merged.Dict(merged.Pages[1].Dictionary, "Resources"), "Font")!.Entries.Select(f => f.Key).ToList();
        foreach (var run in runs.Where(r => r.Pages.Contains(1)))
        {
            Assert.Contains($"/LazyPDF {run.Id}", content);
            Assert.Contains($"LPS{run.Id}_F", fonts);
            Assert.Contains($"/LPS{run.Id}_F ", content);
        }
        var bTwo = runs.Single(r => r.Label == "BTWO");
        Assert.Equal([1], bTwo.Pages);
        Assert.Equal(1, stamper.Remove(bTwo.Id));
        Assert.Equal("AONEATWO", StampKit.Text(StampKit.Glyphs(merged, 0)));
        Assert.Equal("BONE", StampKit.Text(StampKit.Glyphs(merged, 1)));
    }

    [Fact]
    public void LabelsThatDifferOnlyInNormalisationAreDifferentRuns()
    {
        var a = StampKit.Doc(1);
        var b = StampKit.Doc(1);
        new PdfStamper(a).AddWatermark(new WatermarkSpec { Text = "AB", Behind = true });
        new PdfStamper(b).AddWatermark(new WatermarkSpec { Text = "AB", Behind = true });
        Marker(a, 0)["Label"] = PdfText.ToObject("é");
        Marker(b, 0)["Label"] = PdfText.ToObject("é");

        var merged = PageAssembly.Merge([new MergeSource(a), new MergeSource(b)]);

        var runs = new PdfStamper(merged).List();
        Assert.Equal(2, runs.Count);
        Assert.Equal(["é", "é"], runs.Select(r => r.Label));
    }

    // The first stream on the page that carries a run's marker.
    private static PdfDictionary Marker(PdfDocument document, int page) =>
        StampKit.ContentStreams(document, page).Select(d => document.Dict(d, "LazyPDF")).First(m => m is not null && m["Id"] is not null)!;

    [Fact]
    public void AMarkerIdOutsideAnIntIsNotARun()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        stamper.AddWatermark(new WatermarkSpec { Text = "ONE", Behind = true });
        Marker(document, 0)["Id"] = new PdfNumber(4294967297L);

        Assert.Empty(stamper.List());
        Assert.Equal(0, stamper.Remove(1));
        Assert.Equal(0, stamper.RemoveAll());
        Assert.Equal(1, stamper.AddWatermark(new WatermarkSpec { Text = "TWO" }).Id);
    }

    [Fact]
    public void AnIdAtTheTopOfTheRangeGetsAFreshOne()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        stamper.AddWatermark(new WatermarkSpec { Text = "ONE", Behind = true });
        Marker(document, 0)["Id"] = new PdfNumber(int.MaxValue);

        Assert.Equal(1, stamper.AddWatermark(new WatermarkSpec { Text = "TWO", Behind = true }).Id);
        Assert.Equal(2, stamper.AddWatermark(new WatermarkSpec { Text = "THREE", Behind = true }).Id);
        Assert.Equal([1, 2, int.MaxValue], stamper.List().Select(s => s.Id));
        Assert.Equal(1, stamper.Remove(int.MaxValue));
        Assert.Equal(2, stamper.List().Count);
    }

    [Fact]
    public async Task ALayerListThatHoldsItselfIsStrippedOnce()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "DRAFT", LayerName = "Marks" });
        var order = new PdfArray([]);
        var self = document.Add(order);
        for (int i = 0; i < 40; i++) order.Items.Add(self);
        var properties = document.Dict(document.Catalog, "OCProperties")!;
        document.Dict(properties, "D")!["Order"] = self;

        await Task.Run(() => stamper.Remove(run.Id)).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Empty(stamper.List());
    }

    [Fact]
    public void AKindIsReadByItsNameOnly()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        stamper.AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "x", "") });
        Assert.Equal(StampKind.HeaderFooter, Assert.Single(stamper.List()).Kind);
        var marker = Marker(document, 0);
        foreach (string odd in new[] { "3", "99", "Background,Bates", " Bates", "bates" })
        {
            marker["Kind"] = new PdfName(odd);
            Assert.Equal(StampKind.Watermark, Assert.Single(stamper.List()).Kind);
        }
        marker["Kind"] = new PdfName("Bates");
        Assert.Equal(StampKind.Bates, Assert.Single(stamper.List()).Kind);
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
