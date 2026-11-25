using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OcrLayerCorrectionTests
{
    private static PdfDocument WithLayer(string pageEntries = "")
    {
        var document = OcrKit.Scan(1, pageEntries);
        var geometry = new PageGeometry(document.Pages[0]);
        PdfOcrLayer.Add(document, [new OcrPageWords(0, OcrKit.Words(), (int)geometry.Width, (int)geometry.Height)], "en-US");
        return document;
    }

    private static PdfReference FontOf(PdfDocument document) =>
        (PdfReference)document.Dict(document.Pages[0].Resources, "Font")!["LPOcrF"]!;

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void ChangedWordKeepsItsBox(int rotate)
    {
        var document = WithLayer($"/Rotate {rotate}");
        PdfOcrLayer.Correct(document, document.Pages[0], 1, "earth");

        var found = OcrKit.Located(document);
        Assert.Equal(["Hello", "earth", "Second", "line"], found.Select(f => f.Text));
        var box = found[1].Box;
        Assert.True(Math.Abs(box.X - 160) < 1 && Math.Abs(box.Y - 100) < 1 && Math.Abs(box.Width - 110) < 1 && Math.Abs(box.Height - 24) < 1, box.ToString());
        Assert.Equal(1, OcrKit.LayerStreams(document));
    }

    [Fact]
    public void ChangeSurvivesSavingAndReopening()
    {
        var document = WithLayer();
        PdfOcrLayer.Correct(document, document.Pages[0], 2, "Third");
        var file = document.SaveRewrite();
        using var reopened = PdfDocument.Open(file);
        Assert.Equal(["Hello", "world", "Third", "line"], OcrKit.Located(reopened).Select(f => f.Text));
        Assert.Contains("Third line", OcrKit.PigText(file));

        PdfOcrLayer.Correct(reopened, reopened.Pages[0], 0, "Hi");
        using var again = PdfDocument.Open(reopened.SaveIncremental());
        Assert.Equal(["Hi", "world", "Third", "line"], PdfOcrLayer.Words(again, again.Pages[0]).Select(w => w.Text));
    }

    [Fact]
    public void RepeatedChangesDoNotMoveTheBox()
    {
        var document = WithLayer();
        var before = PdfOcrLayer.Words(document, document.Pages[0])[3].Box;
        for (int i = 0; i < 20; i++) PdfOcrLayer.Correct(document, document.Pages[0], 3, i % 2 == 0 ? "lines" : "line");
        var after = PdfOcrLayer.Words(document, document.Pages[0])[3].Box;
        Assert.True(Math.Abs(before.X - after.X) < 0.001 && Math.Abs(before.Width - after.Width) < 0.001 && Math.Abs(before.Y - after.Y) < 0.001);
    }

    [Fact]
    public void EmptyTextRemovesTheWordAndAnEmptiedLine()
    {
        var document = WithLayer();
        PdfOcrLayer.Correct(document, document.Pages[0], 1, "  ");
        Assert.Equal(["Hello", "Second", "line"], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
        PdfOcrLayer.Correct(document, document.Pages[0], 0, "");
        PdfOcrLayer.Correct(document, document.Pages[0], 0, "");
        PdfOcrLayer.Correct(document, document.Pages[0], 0, "");
        Assert.Empty(PdfOcrLayer.Words(document, document.Pages[0]));
        Assert.Empty(TextPage.Create(document, document.Pages[0]).Words);
    }

    [Fact]
    public void FontIsKeptForPlainTextAndReplacedForANewWideCharacter()
    {
        var document = WithLayer();
        var font = FontOf(document);
        PdfOcrLayer.Correct(document, document.Pages[0], 0, "ğüşİı");
        Assert.Equal(font, FontOf(document));

        string wide = char.ConvertFromUtf32(0x1F600);
        PdfOcrLayer.Correct(document, document.Pages[0], 1, wide);
        Assert.NotEqual(font, FontOf(document));
        var second = FontOf(document);
        Assert.Equal(["ğüşİı", wide, "Second", "line"], TextPage.Create(document, document.Pages[0]).Words.Select(w => w.Text));

        // The font already has the character now, and another word may use it too.
        PdfOcrLayer.Correct(document, document.Pages[0], 2, wide + wide);
        Assert.Equal(second, FontOf(document));
        Assert.Equal(["ğüşİı", wide, wide + wide, "line"], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
    }

    [Fact]
    public void WideCharactersOfOtherWordsKeepTheirCodesWhenTheFontIsReplaced()
    {
        var document = OcrKit.Scan();
        string a = char.ConvertFromUtf32(0x20000), b = char.ConvertFromUtf32(0x1F600), c = char.ConvertFromUtf32(0x1F601);
        PdfOcrLayer.Add(document, [new OcrPageWords(0, [OcrKit.Word(a, 10, 10, 40, 20), OcrKit.Word(b, 60, 10, 40, 20), OcrKit.Word("x", 110, 10, 40, 20)], 400, 600)], "en");
        PdfOcrLayer.Correct(document, document.Pages[0], 2, c);
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal([a, b, c], TextPage.Create(reopened, reopened.Pages[0]).Words.Select(w => w.Text));
    }

    [Fact]
    public void DuplicatedPageKeepsItsOwnWordsWhenTheOtherIsChangedOrLosesItsLayer()
    {
        var document = WithLayer();
        PageOperations.Duplicate(document, [0]);
        PdfOcrLayer.Correct(document, document.Pages[0], 0, char.ConvertFromUtf32(0x20000));
        Assert.Equal(char.ConvertFromUtf32(0x20000), PdfOcrLayer.Words(document, document.Pages[0])[0].Text);
        Assert.Equal("Hello", PdfOcrLayer.Words(document, document.Pages[1])[0].Text);
        Assert.Equal("Hello", TextPage.Create(document, document.Pages[1]).Words[0].Text);

        PdfOcrLayer.Remove(document, document.Pages[0]);
        Assert.False(PdfOcrLayer.Has(document, document.Pages[0]));
        Assert.Equal(["Hello", "world", "Second", "line"], TextPage.Create(document, document.Pages[1]).Words.Select(w => w.Text));
    }

    [Fact]
    public void NoSuchWordOrNoLayerThrows()
    {
        var document = WithLayer();
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Correct(document, document.Pages[0], 4, "x"));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Correct(document, document.Pages[0], -1, "x"));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Correct(OcrKit.Scan(), OcrKit.Scan().Pages[0], 0, "x"));
        Assert.Equal(["Hello", "world", "Second", "line"], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
    }

    [Fact]
    public void CorrectedFileOpensInPdfPig()
    {
        var document = WithLayer("/Rotate 90");
        PdfOcrLayer.Correct(document, document.Pages[0], 0, char.ConvertFromUtf32(0x20000));
        PdfOcrLayer.Correct(document, document.Pages[0], 1, "Welt");
        string text = OcrKit.PigText(document.SaveRewrite());
        Assert.Contains("Welt", text);
        Assert.Contains("Second line", text);
    }

    [Fact]
    public void ALayerStreamNextToAnotherKeepsItsWideCharactersWhenTheFontIsReplaced()
    {
        var document = OcrKit.Scan();
        string a = char.ConvertFromUtf32(0x1F600), b = char.ConvertFromUtf32(0x20000), c = char.ConvertFromUtf32(0x1F601);
        PdfOcrLayer.Add(document, [new OcrPageWords(0, [OcrKit.Word(a, 10, 10, 40, 20)], 400, 600), new OcrPageWords(0, [OcrKit.Word(b, 10, 100, 40, 20)], 400, 600)], "en");
        Assert.Equal(2, OcrKit.LayerStreams(document));
        Assert.Equal([b, a], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));

        PdfOcrLayer.Correct(document, document.Pages[0], 1, c);

        Assert.Equal([b, c], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
    }

    [Fact]
    public void WordNumbersAtTheEdgesOfTheIntegersThrow()
    {
        var document = WithLayer();
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Correct(document, document.Pages[0], int.MaxValue, "x"));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Correct(document, document.Pages[0], int.MinValue, "x"));
    }
}
