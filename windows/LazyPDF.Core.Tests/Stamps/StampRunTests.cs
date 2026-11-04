using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StampRunTests
{
    private static string Names(PdfDocument document, int page, string category) =>
        string.Join(",", (document.Dict(document.Pages[page].Resources, category)?.Entries ?? []).Select(e => e.Key));

    [Fact]
    public void RunsGetIncreasingIdsAndAreListed()
    {
        var document = StampKit.Doc(3);
        var stamper = new PdfStamper(document);
        var mark = stamper.AddWatermark(new WatermarkSpec { Text = "ONE", Pages = [0, 1] });
        var ground = stamper.AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.9) });
        var notes = stamper.AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "{page}", "") });
        Assert.Equal([1, 2, 3], new[] { mark.Id, ground.Id, notes.Id });

        var all = stamper.List();
        Assert.Equal([StampKind.Watermark, StampKind.Background, StampKind.HeaderFooter], all.Select(s => s.Kind));
        Assert.Equal([0, 1], all[0].Pages);
        Assert.Equal([0, 1, 2], all[2].Pages);
        Assert.Equal([2, 3], stamper.List(document.Pages[2]).Select(s => s.Id));
        Assert.Equal("{page}", all[2].Label);
    }

    [Fact]
    public void ARunSurvivesSavingAndIsFoundAgain()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "KEEP" });
        using var rewritten = PdfDocument.Open(StampKit.Rewrite(document));
        Assert.Equal(1, Assert.Single(new PdfStamper(rewritten).List()).Id);
        using var incremental = PdfDocument.Open(document.SaveIncremental());
        var stamper = new PdfStamper(incremental);
        Assert.Equal(1, Assert.Single(stamper.List()).Id);
        Assert.Equal(2, stamper.AddWatermark(new WatermarkSpec { Text = "NEXT" }).Id);
    }

    [Fact]
    public void RemovingARunRestoresThePage()
    {
        var document = StampKit.Doc(2);
        var before = StampKit.Latin(document, 0);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "GONE", LayerName = "Mark", Opacity = 0.5 });
        stamper.AddWatermark(new WatermarkSpec { Text = "STAYS", Pages = [1] });

        Assert.Equal(2, stamper.Remove(run.Id));
        Assert.Equal(before, StampKit.Latin(document, 0));
        Assert.Equal("", Names(document, 0, "ExtGState"));
        Assert.Equal("", Names(document, 0, "Properties"));
        Assert.Equal("F1", Names(document, 0, "Font"));
        Assert.Null(document.Dict(document.Catalog, "OCProperties"));
        Assert.Equal("STAYS", StampKit.Text(StampKit.Glyphs(document, 1)));
        Assert.Equal(0, stamper.Remove(run.Id));
    }

    [Fact]
    public void RemovingTheLastFrontStampTakesTheWrapperToo()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "WRAP" });
        Assert.Equal(4, StampKit.ContentStreams(document, 0).Count);
        stamper.Remove(run.Id);
        Assert.Single(StampKit.ContentStreams(document, 0));
        Assert.Equal("BT /F1 12 Tf 50 50 Td (1) Tj ET", StampKit.Latin(document, 0));
    }

    [Fact]
    public void FrontStampsShareOneWrapper()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        var a = stamper.AddWatermark(new WatermarkSpec { Text = "A" });
        var b = stamper.AddHeaderFooter(new HeaderFooterSpec { Header = new("h", "", "") });
        stamper.AddBackground(new BackgroundSpec { Color = StampColor.Black });
        Assert.Equal(1 + 2 + 2 + 1, StampKit.ContentStreams(document, 0).Count);

        stamper.Remove(a.Id);
        Assert.Equal(1 + 2 + 1 + 1, StampKit.ContentStreams(document, 0).Count);
        stamper.Remove(b.Id);
        Assert.Equal(2, StampKit.ContentStreams(document, 0).Count);
        Assert.True(stamper.RemoveAll() == 1);
        Assert.Single(StampKit.ContentStreams(document, 0));
    }

    [Fact]
    public void UpdateReplacesTheRunUnderTheSameId()
    {
        var document = StampKit.Doc(3);
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "OLD", Opacity = 0.2 });
        var updated = stamper.Update(run.Id, new WatermarkSpec { Text = "NEW", Opacity = 0.8, Pages = [1] });

        Assert.Equal(run.Id, updated.Id);
        var info = Assert.Single(stamper.List());
        Assert.Equal(("NEW", 1), (info.Label, info.Pages.Single()));
        Assert.Empty(StampKit.Glyphs(document, 0));
        Assert.Equal("NEW", StampKit.Text(StampKit.Glyphs(document, 1)));
        Assert.Equal("", Names(document, 2, "ExtGState"));
        var state = document.Dict(document.Dict(document.Pages[1].Resources, "ExtGState"), "LPS1_G")!;
        Assert.Equal(0.8, document.Number(state, "ca"));
    }

    [Fact]
    public void UpdateOfAnUnknownIdAddsTheRun()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        stamper.Update(7, new HeaderFooterSpec { Header = new("", "x", "") });
        Assert.Equal(7, Assert.Single(stamper.List()).Id);
    }

    [Fact]
    public void RemovingAfterReopeningLeavesTheCleanFile()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "TEMP", LayerName = "L" });
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "{page}", "") });
        using var reopened = PdfDocument.Open(StampKit.Rewrite(document));
        var stamper = new PdfStamper(reopened);

        Assert.Equal(2, stamper.RemoveAll());
        Assert.Empty(stamper.List());
        var clean = StampKit.Rewrite(reopened);
        Assert.Equal("1", StampKit.PigText(clean).Trim());
        using var again = PdfDocument.Open(clean);
        Assert.Empty(StampKit.Glyphs(again, 0));
        Assert.Null(again.Dict(again.Catalog, "OCProperties"));
    }

    [Fact]
    public void ARunOnPagesWithSharedResourcesWorks()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300] /Resources 7 0 R>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>");
        pdf.Stream(5, "", "BT /F1 12 Tf 50 50 Td (a) Tj ET");
        pdf.Stream(6, "", "BT /F1 12 Tf 50 50 Td (b) Tj ET");
        pdf.Obj(7, "<</Font <</F1 8 0 R>>>>");
        pdf.Obj(8, ContentTestPdf.Helvetica);
        var document = PdfDocument.Open(pdf.Finish());
        var stamper = new PdfStamper(document);
        var run = stamper.AddWatermark(new WatermarkSpec { Text = "SHARED" });
        Assert.Equal("SHARED", StampKit.Text(StampKit.Glyphs(document, 1)));
        stamper.Remove(run.Id);
        Assert.Equal("F1", Names(document, 0, "Font"));
        Assert.Empty(StampKit.Glyphs(document, 0));
    }

    [Fact]
    public void APageWithoutContentsOrWithAnArrayTakesStamps()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents [5 0 R 6 0 R]>>");
        pdf.Stream(5, "", "q 1 0 0 1 0 0 cm");
        pdf.Stream(6, "", "0 0 10 10 re f");
        var document = PdfDocument.Open(pdf.Finish());
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "BOTH" });
        Assert.Equal("BOTH", StampKit.Text(StampKit.Glyphs(document, 0)));
        Assert.Equal("BOTH", StampKit.Text(StampKit.Glyphs(document, 1)));
        using var reopened = PdfDocument.Open(StampKit.Rewrite(document));
        Assert.Equal(2, new PdfStamper(reopened).List()[0].Pages.Count);
    }
}
