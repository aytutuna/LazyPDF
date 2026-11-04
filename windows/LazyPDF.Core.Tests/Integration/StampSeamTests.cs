using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StampSeamTests
{
    private static readonly HeaderFooterSpec Header = new() { Header = new HeaderFooterBand(Left: "HEADERMARK"), Footer = new HeaderFooterBand(Center: "{page} of {pages}") };

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void HeaderIsUprightAtTheTopOfARotatedPage(int rotate)
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(2, pageExtra: $"/Rotate {rotate}"));
        new PdfStamper(document).AddHeaderFooter(Header);

        var bytes = document.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);
        var again = PdfDocument.Open(bytes);
        var page = again.Pages[1];
        var geometry = new PageGeometry(page);
        var text = TextPage.Create(again, page);
        var word = text.Words.Single(w => w.Text == "HEADERMARK");
        var chars = Enumerable.Range(word.Range.Start, word.Range.Count).Select(i => text.Chars[i]).ToList();

        var (x0, y0) = geometry.ToDisplay(chars[0].Quad.X0, chars[0].Quad.Y0);
        var (x1, y1) = geometry.ToDisplay(chars[^1].Quad.X1, chars[^1].Quad.Y1);
        Assert.True(x1 - x0 > 30, "reads left to right");
        Assert.True(Math.Abs(y1 - y0) < 0.01, "on one baseline");
        Assert.True(y0 < 60, "near the top");
        Assert.True(x0 < 60, "at the left margin");
        Assert.Contains(text.Words, w => w.Text == "2");
    }

    [Fact]
    public void RunsSurviveRotateDeleteAndReorder()
    {
        var session = PdfEditSession.Open(IntegrationFiles.Form(4));
        var stamper = new PdfStamper(session.Document);
        var header = stamper.AddHeaderFooter(Header).Id;
        var mark = stamper.AddWatermark(new WatermarkSpec { Text = "DRAFT", LayerName = "Draft" }).Id;
        Assert.True(session.Commit("stamp"));

        PageOperations.Rotate(session.Document, [0, 1], 90);
        PageOperations.Delete(session.Document, [2]);
        PageOperations.Reorder(session.Document, [2, 0, 1]);
        Assert.True(session.Commit("pages"));

        var document = IntegrationFiles.Reopen(session);
        var list = new PdfStamper(document).List();
        Assert.Equal([header, mark], list.Select(i => i.Id));
        Assert.All(list, i => Assert.Equal(3, i.Pages.Count));

        new PdfStamper(document).Remove(mark);
        Assert.Single(new PdfStamper(document).List());
        IntegrationFiles.ReadBack(document.SaveRewrite());
    }

    [Fact]
    public void StampsTravelWithExtractedAndMergedPages()
    {
        var first = PdfDocument.Open(IntegrationFiles.Form(2));
        var second = PdfDocument.Open(IntegrationFiles.Form(2));
        new PdfStamper(first).AddWatermark(new WatermarkSpec { Text = "ONE" });
        new PdfStamper(second).AddWatermark(new WatermarkSpec { Text = "TWO" });

        var merged = PageAssembly.Merge([new MergeSource(first, [1]), new MergeSource(second, [0])]);
        var bytes = merged.SaveRewrite();
        var texts = IntegrationFiles.ReadBack(bytes);
        Assert.Contains("ONE", texts[0]);
        Assert.Contains("TWO", texts[1]);

        // Both runs were id 1 in their own files; the merge gives them ids of their own.
        var again = PdfDocument.Open(bytes);
        var stamper = new PdfStamper(again);
        Assert.Equal(2, stamper.List().Count);
        Assert.Equal(1, stamper.Remove(stamper.List().Single(r => r.Label == "ONE").Id));
        Assert.Equal(1, stamper.Remove(stamper.List().Single().Id));
        var cleaned = IntegrationFiles.ReadBack(again.SaveRewrite());
        Assert.All(cleaned, t => Assert.DoesNotMatch("ONE|TWO", t));
    }

    [Fact]
    public void WatermarkOnCroppedRotatedPageStaysInsideTheCropBox()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1, pageExtra: "/Rotate 270 /CropBox [50 100 350 500]"));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "SECRET", Opacity = 1, Scale = 0.5 });

        var again = PdfDocument.Open(document.SaveRewrite());
        var page = again.Pages[0];
        var geometry = new PageGeometry(page);
        var text = TextPage.Create(again, page);
        var word = text.Words.Single(w => w.Text == "SECRET");
        var bounds = geometry.ToDisplay(word.Bounds);
        Assert.InRange(bounds.X, 0, geometry.Width);
        Assert.InRange(bounds.X + bounds.Width, 0, geometry.Width);
        Assert.InRange(bounds.Y + bounds.Height, 0, geometry.Height);
        Assert.True(bounds.Width > bounds.Height);
    }
}
