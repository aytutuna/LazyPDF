using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A stamp from the form to the file: written by Core, committed through the tab, found again, updated and taken off.
public sealed class StampDraftTests
{
    private static DocumentTab Open(int pages) => new(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, "a.pdf");

    private static IReadOnlyList<StampInfo> Stamps(DocumentTab tab) => new PdfStamper(tab.Document).List();

    private static StampDraft Mark(string text, IReadOnlyList<int>? pages = null) =>
        new(Watermark: new WatermarkSpec { Text = text, Pages = pages });

    [Fact]
    public void AWatermarkIsWrittenOnEveryPageAndUndoTakesItBack()
    {
        using var tab = Open(3);

        var run = Mark("DRAFT").Apply(tab.Document, new FakeFonts(), new FakeCodec(), null);
        Assert.True(tab.Commit("Add watermark"));

        Assert.Equal(3, run.Pages);
        var found = Assert.Single(Stamps(tab));
        Assert.Equal(StampKind.Watermark, found.Kind);
        Assert.Equal("DRAFT", found.Label);
        Assert.Equal([0, 1, 2], found.Pages);

        Assert.True(tab.Undo());
        Assert.Empty(Stamps(tab));
    }

    [Fact]
    public void UpdatingKeepsTheRunsIdAndChangesWhatItDraws()
    {
        using var tab = Open(3);
        var first = Mark("DRAFT").Apply(tab.Document, new FakeFonts(), new FakeCodec(), null);
        tab.Commit("Add watermark");

        Mark("FINAL", [0]).Apply(tab.Document, new FakeFonts(), new FakeCodec(), first.Id);
        tab.Commit("Update stamp");

        var found = Assert.Single(Stamps(tab));
        Assert.Equal(first.Id, found.Id);
        Assert.Equal("FINAL", found.Label);
        Assert.Equal([0], found.Pages);
    }

    [Fact]
    public void RemovingARunLeavesTheOthers()
    {
        using var tab = Open(2);
        var codec = new FakeCodec();
        var first = Mark("ONE").Apply(tab.Document, new FakeFonts(), codec, null);
        Mark("TWO").Apply(tab.Document, new FakeFonts(), codec, null);
        tab.Commit("Add watermark");

        int pages = new PdfStamper(tab.Document).Remove(first.Id);
        tab.Commit("Remove stamp");

        Assert.Equal(2, pages);
        Assert.Equal("TWO", Assert.Single(Stamps(tab)).Label);
    }

    [Fact]
    public void BatesNumbersContinueIntoTheNextDocument()
    {
        using var tab = Open(3);
        var spec = new HeaderFooterSpec
        {
            Footer = new HeaderFooterBand(Right: "{bates}"),
            Bates = new BatesSpec("ACME-", "", 4, 10),
            FileName = "a.pdf",
        };

        var run = new StampDraft(HeaderFooter: spec).Apply(tab.Document, new FakeFonts(), new FakeCodec(), null);
        tab.Commit("Add Bates numbers");

        Assert.Equal(13, run.NextBates);
        Assert.Equal(StampKind.Bates, Assert.Single(Stamps(tab)).Kind);
    }

    [Fact]
    public void HeadersGoOnTheOddPagesOnly()
    {
        using var tab = Open(3);
        var (pages, error) = PageChoice.Resolve(PageSet.Odd, "", tab.PageCount);
        var spec = new HeaderFooterSpec { Header = new HeaderFooterBand(Center: "{file}"), FileName = "a.pdf", Pages = pages };

        new StampDraft(HeaderFooter: spec).Apply(tab.Document, new FakeFonts(), new FakeCodec(), null);
        tab.Commit("Add header and footer");

        Assert.Null(error);
        Assert.Equal([0, 2], Assert.Single(Stamps(tab)).Pages);
    }

    [Fact]
    public void APictureWatermarkTakesTheFileThroughTheCodec()
    {
        using var tab = Open(1);

        var draft = new StampDraft(Watermark: new WatermarkSpec(), Picture: [1, 2, 3]);
        var run = draft.Apply(tab.Document, new FakeFonts(), new FakeCodec(), null);
        tab.Commit("Add watermark");

        Assert.Equal(1, run.Pages);
        Assert.Equal("image", Assert.Single(Stamps(tab)).Label);
    }

    [Fact]
    public void APictureNoCodecCanReadIsRefusedAndNothingIsStamped()
    {
        using var tab = Open(1);
        var draft = new StampDraft(Background: new BackgroundSpec(), Picture: []);

        Assert.Throws<InvalidDataException>(() => draft.Apply(tab.Document, new FakeFonts(), new FakeCodec(), null));

        Assert.Empty(Stamps(tab));
    }

    [Fact]
    public void TextNoFontCanDrawLeavesTheDocumentAlone()
    {
        using var tab = Open(1);

        var error = Assert.Throws<InvalidOperationException>(() => Mark("ğş").Apply(tab.Document, new FakeFonts(), new FakeCodec(), null));

        Assert.Equal(StampsText.NoFont, error.Message);
        Assert.False(tab.Commit("Add watermark"));
    }

    [Fact]
    public void ADraftWithNothingToDrawSaysSo()
    {
        Assert.Equal(StampsText.NeedsContent, Mark("  ").Problem);
        Assert.Equal(StampsText.NeedsContent, new StampDraft(Background: new BackgroundSpec()).Problem);
        Assert.NotNull(new StampDraft(HeaderFooter: new HeaderFooterSpec()).Problem);
        Assert.Null(new StampDraft(HeaderFooter: new HeaderFooterSpec { Bates = new BatesSpec() }).Problem);
        Assert.Null(new StampDraft(Background: new BackgroundSpec { Color = StampColor.Gray(0.9) }).Problem);
        Assert.Null(new StampDraft(Watermark: new WatermarkSpec(), Picture: [1]).Problem);
    }
}
