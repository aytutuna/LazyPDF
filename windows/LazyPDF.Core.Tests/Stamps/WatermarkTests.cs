using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class WatermarkTests
{
    private static readonly byte[] Jpeg = Convert.FromBase64String(StampKit.SampleJpeg);

    [Fact]
    public void TextWatermarkIsPageContentAndReopens()
    {
        var document = StampKit.Doc(2);
        var run = new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "CONFIDENTIAL" });
        Assert.Equal(2, run.Pages);
        var file = StampKit.Rewrite(document);

        Assert.Contains("CONFIDENTIAL", StampKit.PigText(file));
        using var reopened = PdfDocument.Open(file);
        Assert.Equal("CONFIDENTIAL", StampKit.Text(StampKit.Glyphs(reopened, 1)));
        var info = Assert.Single(new PdfStamper(reopened).List());
        Assert.Equal((StampKind.Watermark, "CONFIDENTIAL", false), (info.Kind, info.Label, info.Behind));
    }

    [Fact]
    public void TheTextSpansTheScaleOfThePageWidth()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "WIDTH", Scale = 0.5 });
        var glyphs = StampKit.Glyphs(document, 0);
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Bold, ["WIDTH"])!;
        Assert.Equal(100, font.Width("WIDTH", glyphs[0].Size), 3);
        Assert.Equal(font.Width("WIDT", glyphs[0].Size), glyphs[^1].X - glyphs[0].X, 3);
    }

    [Fact]
    public void ACentredWatermarkIsCentredOnThePage()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "MID", Scale = 0.4 });
        var glyphs = StampKit.Glyphs(document, 0);
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Bold, ["MID"])!;
        double size = glyphs[0].Size;
        Assert.Equal(100 - font.Width("MID", size) / 2, glyphs[0].X, 3);
        double middle = glyphs[0].Y - (font.Ascent + font.Descent) / 2 * size;
        Assert.Equal(150, middle, 3);
    }

    [Fact]
    public void RotationTurnsTheTextCounterClockwise()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "TILT", Rotation = 90 });
        var glyph = StampKit.Glyphs(document, 0)[0];
        Assert.Equal(0, glyph.DirX, 6);
        Assert.Equal(-1, glyph.DirY, 6);
    }

    [Fact]
    public void ARotatedPageStillShowsTheWatermarkAsAskedForOnScreen()
    {
        var document = StampKit.Pages(("/Rotate 90", "BT /F1 12 Tf 50 50 Td (r) Tj ET"));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "SIDE", Rotation = 0 });
        var glyphs = StampKit.Glyphs(document, 0);
        Assert.All(glyphs, g => Assert.Equal((1, 0), (Math.Round(g.DirX, 6), Math.Round(g.DirY, 6))));
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Bold, ["SIDE"])!;
        Assert.Equal(150 - font.Width("SIDE", glyphs[0].Size) / 2, glyphs[0].X, 3);
        Assert.Equal(0.6 * 300, font.Width("SIDE", glyphs[0].Size), 3);
    }

    [Fact]
    public void OpacityIsAnExtGState()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "FADE", Opacity = 0.25 });
        Assert.All(StampKit.Glyphs(document, 0), g => Assert.Equal(0.25, g.Alpha, 6));
        var state = document.Dict(document.Dict(document.Pages[0].Resources, "ExtGState"), "LPS1_G")!;
        Assert.Equal(0.25, document.Number(state, "ca"));
        Assert.Equal(0.25, document.Number(state, "CA"));
    }

    [Fact]
    public void FullOpacityAddsNoGraphicsState()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "SOLID", Opacity = 1 });
        Assert.Null(document.Dict(document.Pages[0].Resources, "ExtGState"));
    }

    [Fact]
    public void BehindComesBeforeThePageAndInFrontAfterIt()
    {
        var back = StampKit.Doc(1);
        new PdfStamper(back).AddWatermark(new WatermarkSpec { Text = "UNDER", Behind = true });
        string behind = StampKit.Latin(back, 0);
        Assert.StartsWith("q\n", behind);
        Assert.True(behind.IndexOf("/Artifact", StringComparison.Ordinal) < behind.IndexOf("(1)", StringComparison.Ordinal));

        var front = StampKit.Doc(1);
        new PdfStamper(front).AddWatermark(new WatermarkSpec { Text = "OVER" });
        string text = StampKit.Latin(front, 0);
        Assert.True(text.IndexOf("(1)", StringComparison.Ordinal) < text.IndexOf("/Artifact", StringComparison.Ordinal));
    }

    [Fact]
    public void OnlyTheListedPagesGetIt()
    {
        var document = StampKit.Doc(4);
        var run = new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "SOME", Pages = [2, 0, 9, -1, 2] });
        Assert.Equal(2, run.Pages);
        var info = Assert.Single(new PdfStamper(document).List());
        Assert.Equal([0, 2], info.Pages);
        Assert.Empty(StampKit.Glyphs(document, 1));
        Assert.Equal(4, StampKit.Glyphs(document, 2).Count);
    }

    [Fact]
    public void AnImageWatermarkIsScaledAndKeepsItsProportions()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddJpeg(document, Jpeg)!;
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Image = image, Scale = 0.5 });
        var file = StampKit.Rewrite(document);

        using var pig = PigDocument.Open(file);
        Assert.Single(pig.GetPage(1).GetImages());
        using var reopened = PdfDocument.Open(file);
        var recorder = ContentTestPdf.Run(reopened);
        var placed = Assert.Single(recorder.Images);
        Assert.Equal(100, placed.Bounds.Width, 3);
        Assert.Equal(75, placed.Bounds.Height, 3);
        Assert.Equal(50, placed.Bounds.Left, 3);
    }

    [Fact]
    public void AnchorAndOffsetMoveItInDisplayPoints()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "TL", Scale = 0.2, Anchor = StampAnchor.TopLeft, OffsetX = 10, OffsetY = 20 });
        var glyphs = StampKit.Glyphs(document, 0);
        Assert.Equal(10, glyphs[0].X, 3);
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Bold, ["TL"])!;
        Assert.Equal(20 + font.Ascent * glyphs[0].Size, glyphs[0].Y, 3);
    }

    [Fact]
    public void MultipleLinesAreCentredOnEachOther()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "LONGER LINE\nAB" });
        var glyphs = StampKit.Glyphs(document, 0);
        var first = glyphs.First(g => g.Text == "L");
        var second = glyphs.First(g => g.Text == "A");
        Assert.True(second.Y > first.Y);
        Assert.True(second.X > first.X);
    }

    [Fact]
    public void ALayerMakesItOptionalContent()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "LAYERED", LayerName = "Watermark" });
        var file = StampKit.Rewrite(document);
        using var reopened = PdfDocument.Open(file);

        var properties = reopened.Dict(reopened.Catalog, "OCProperties")!;
        var groups = reopened.Array(properties, "OCGs")!;
        var group = (PdfDictionary)reopened.Resolve(Assert.Single(groups.Items))!;
        Assert.Equal("OCG", reopened.Name(group, "Type"));
        Assert.Single(reopened.Array(reopened.Dict(properties, "D"), "Order")!.Items);
        Assert.Contains("/OC /LPS1_P BDC", StampKit.Latin(reopened, 1));
        Assert.Same(group, reopened.Dict(reopened.Dict(reopened.Pages[1].Resources, "Properties"), "LPS1_P"));

        var seen = new List<PdfDictionary?>();
        new ContentInterpreter(reopened).Run(reopened.Pages[0], new LayerVisitor(seen));
        Assert.Equal(7, seen.Count);
        Assert.All(seen, o => Assert.Same(group, o));
    }

    private sealed class LayerVisitor(List<PdfDictionary?> seen) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (context.Marked.Any(m => m.Tag == "Artifact")) seen.Add(context.OptionalContent);
        }
    }

    [Fact]
    public void TurkishTextEmbedsAFontAndReadsBack()
    {
        var document = StampKit.Doc(1);
        const string text = "ĞÜŞİ ığüşöç";
        var run = new PdfStamper(document, new ArialSource()).AddWatermark(new WatermarkSpec { Text = text });
        Assert.Empty(run.Missing);
        var file = StampKit.Rewrite(document);
        Assert.Contains(text, StampKit.PigText(file));
        using var reopened = PdfDocument.Open(file);
        Assert.Equal(text, StampKit.Text(StampKit.Glyphs(reopened, 0)));
    }

    [Fact]
    public void WithoutAFontForTheTextNothingIsChanged()
    {
        var document = StampKit.Doc(1);
        var error = Assert.Throws<InvalidOperationException>(() => new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "Şişli" }));
        Assert.Equal(StampsText.NoFont, error.Message);
        Assert.Empty(new PdfStamper(document).List());
        Assert.Empty(StampKit.Glyphs(document, 0));
    }

    [Fact]
    public void NeitherTextNorImageIsRefused()
    {
        var document = StampKit.Doc(1);
        var stamper = new PdfStamper(document);
        Assert.Throws<ArgumentException>(() => stamper.AddWatermark(new WatermarkSpec()));
        var image = PdfImageWriter.AddRgba(document, 1, 1, [1, 2, 3, 255]);
        Assert.Throws<ArgumentException>(() => stamper.AddWatermark(new WatermarkSpec { Text = "x", Image = image }));
    }

    [Fact]
    public void WatermarksOnAnIncrementalSaveReopenToo()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "UPDATE", Rotation = 30 });
        var file = document.SaveIncremental();
        Assert.Contains("UPDATE", StampKit.PigText(file, 2));
        using var reopened = PdfDocument.Open(file);
        Assert.Equal(2, Assert.Single(new PdfStamper(reopened).List()).Pages.Count);
    }
}
