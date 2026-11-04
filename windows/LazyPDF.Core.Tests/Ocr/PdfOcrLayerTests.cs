using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfOcrLayerTests
{
    private static int AddWords(PdfDocument document, IReadOnlyList<OcrWord> words, int width = 400, int height = 600, int pageIndex = 0) =>
        PdfOcrLayer.Add(document, [new OcrPageWords(pageIndex, words, width, height)], "en-US");

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void WordsSitOnTheirBoxesOnTheShownPage(int rotate)
    {
        var document = OcrKit.Scan(1, $"/Rotate {rotate}");
        var geometry = new PageGeometry(document.Pages[0]);
        Assert.Equal(rotate is 90 or 270 ? 600 : 400, geometry.Width);
        AddWords(document, OcrKit.Words(), (int)geometry.Width, (int)geometry.Height);
        OcrKit.AssertAtBoxes(document);
    }

    [Fact]
    public void PictureSizeScalesTheBoxes()
    {
        var document = OcrKit.Scan();
        AddWords(document, OcrKit.Words(dpi: 300), 400 * 300 / 72, 600 * 300 / 72);
        OcrKit.AssertAtBoxes(document);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void FileReopensAndPdfPigReadsTheWords(int rotate)
    {
        var document = OcrKit.Scan(1, $"/Rotate {rotate}");
        var geometry = new PageGeometry(document.Pages[0]);
        AddWords(document, OcrKit.Words(), (int)geometry.Width, (int)geometry.Height);

        foreach (byte[] file in new[] { document.SaveRewrite(), document.SaveRewrite(new PdfSaveOptions(UseObjectStreams: true)), document.SaveIncremental() })
        {
            using var reopened = PdfDocument.Open(file);
            Assert.True(PdfOcrLayer.Has(reopened, reopened.Pages[0]));
            OcrKit.AssertAtBoxes(reopened);
            string text = OcrKit.PigText(file);
            Assert.Contains("Hello world", text);
            Assert.Contains("Second line", text);
        }
    }

    [Fact]
    public void LayerIsInvisibleTextInAGlyphlessFontAndKeepsTheStateOfThePage()
    {
        var document = OcrKit.Scan();
        AddWords(document, OcrKit.Words());
        var page = document.Pages[0];
        string content = OcrKit.Latin(page.Contents());
        Assert.StartsWith("q\n", content);
        Assert.Contains("3 Tr", content);
        Assert.EndsWith("/Im1 Do Q", content);
        Assert.Equal(1, OcrKit.LayerStreams(document));

        var font = PdfFont.Get(document, document.Dict(document.Dict(page.Resources, "Font"), "LPOcrF")!);
        Assert.True(font.IsComposite);
        Assert.True(font.IsEmbedded);
        Assert.True(font.HasToUnicode);
        var drawn = new Recorder();
        new ContentInterpreter(document).Run(page, drawn);
        Assert.Single(drawn.Images);
        Assert.All(drawn.RenderModes, mode => Assert.Equal(3, mode));
        Assert.Contains("Hello world", drawn.Text);
    }

    [Fact]
    public void AddTwiceLeavesOneLayerWithTheNewWords()
    {
        var document = OcrKit.Scan();
        AddWords(document, OcrKit.Words());
        AddWords(document, [OcrKit.Word("Only", 40, 100, 80, 24)]);
        Assert.Equal(1, OcrKit.LayerStreams(document));
        Assert.Equal(["Only"], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
        Assert.NotNull(document.Dict(document.Dict(document.Pages[0].Resources, "Font"), "LPOcrF"));
    }

    [Fact]
    public void NothingRecognizedLeavesNoLayer()
    {
        var document = OcrKit.Scan();
        AddWords(document, OcrKit.Words());
        Assert.Equal(0, AddWords(document, []));
        Assert.False(PdfOcrLayer.Has(document, document.Pages[0]));
        Assert.Null(document.Dict(document.Dict(document.Pages[0].Resources, "Font"), "LPOcrF"));
        Assert.Equal("q 400 0 0 600 0 0 cm /Im1 Do Q", OcrKit.Latin(document.Pages[0].Contents()));
    }

    [Fact]
    public void RemoveTakesTheLayerAndFontAwayAndLeavesOthersAlone()
    {
        var document = OcrKit.Pages("BT /F1 12 Tf 50 500 Td (Printed) Tj ET");
        AddWords(document, OcrKit.Words());
        Assert.True(PdfOcrLayer.Remove(document, document.Pages[0]));
        Assert.False(PdfOcrLayer.Remove(document, document.Pages[0]));
        Assert.Equal(["Printed"], TextPage.Create(document, document.Pages[0]).Words.Select(w => w.Text));
        Assert.NotNull(document.Dict(document.Dict(document.Pages[0].Resources, "Font"), "F1"));
    }

    [Fact]
    public void LayerGoesFirstAndWorksWithUnbalancedPageContent()
    {
        var document = OcrKit.Pages("q q BT /F1 12 Tf 50 500 Td (Printed) Tj ET Q Q Q 1 0 0 rg");
        AddWords(document, OcrKit.Words());
        var texts = TextPage.Create(document, document.Pages[0]).Words.Select(w => w.Text).ToList();
        Assert.Contains("Printed", texts);
        Assert.Contains("Hello", texts);
        var printed = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[0], printed);
        Assert.Contains(printed.Glyphs, g => g.Unicode == "P");
    }

    [Fact]
    public void SharedResourcesAreNotChangedForOtherPages()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 400 600]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>");
        pdf.Stream(5, "", "q Q");
        pdf.Obj(6, OcrKit.Helvetica);
        pdf.Obj(7, "<</Font <</F1 6 0 R>>>>");
        var document = PdfDocument.Open(pdf.Finish());
        AddWords(document, OcrKit.Words());
        Assert.True(PdfOcrLayer.Has(document, document.Pages[0]));
        Assert.False(PdfOcrLayer.Has(document, document.Pages[1]));
        Assert.Null(document.Dict(document.Dict(document.Pages[1].Resources, "Font"), "LPOcrF"));
        Assert.NotNull(document.Dict(document.Dict(document.Pages[0].Resources, "Font"), "F1"));
    }

    [Fact]
    public void PageWithoutContentsOrWithInheritedResourcesTakesALayer()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 400 600] /Resources <</Font <</F1 4 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(4, OcrKit.Helvetica);
        var document = PdfDocument.Open(pdf.Finish());
        AddWords(document, OcrKit.Words());
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        OcrKit.AssertAtBoxes(reopened);
        Assert.NotNull(reopened.Dict(reopened.Dict(reopened.Pages[0].Resources, "Font"), "F1"));
    }

    [Fact]
    public void CharactersBeyondTheBmpAndTurkishLettersSurvive()
    {
        var document = OcrKit.Scan();
        string wide = char.ConvertFromUtf32(0x20000) + char.ConvertFromUtf32(0x1F600);
        AddWords(document, [OcrKit.Word("ğüşİıÖ", 40, 100, 120, 24), OcrKit.Word(wide, 180, 100, 60, 24), OcrKit.Word("𠀀𠀁", 260, 100, 60, 24)]);
        string[] expected = ["ğüşİıÖ", wide, "𠀀𠀁"];
        Assert.Equal(expected, TextPage.Create(document, document.Pages[0]).Words.Select(w => w.Text));
        Assert.Equal(expected, PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));

        var file = document.SaveRewrite();
        using var reopened = PdfDocument.Open(file);
        Assert.Equal(expected, TextPage.Create(reopened, reopened.Pages[0]).Words.Select(w => w.Text));
        Assert.Contains("ğüşİıÖ", OcrKit.PigText(file));
    }

    [Fact]
    public void RightToLeftWordsReadInLogicalOrderBack()
    {
        var document = OcrKit.Scan();
        // The recognizer reports the first word of a Hebrew line at the right.
        AddWords(document, [OcrKit.Word("שלום", 250, 100, 80, 24), OcrKit.Word("עולם", 150, 100, 80, 24),
                            OcrKit.Word("مرحبا", 250, 160, 80, 24), OcrKit.Word("بالعالم", 140, 160, 90, 24)]);
        var page = TextPage.Create(document, document.Pages[0]);
        Assert.Equal("שלום עולם\nمرحبا بالعالم", page.Text.Trim());
        Assert.Equal(new[] { "שלום", "עולם", "مرحبا", "بالعالم" }.Order(), PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text).Order());
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal(page.Text, TextPage.Create(reopened, reopened.Pages[0]).Text);
    }

    [Fact]
    public void NumbersInsideAnRightToLeftWordKeepTheirOrder()
    {
        var document = OcrKit.Scan();
        AddWords(document, [OcrKit.Word("סעיף3.14", 200, 100, 100, 24), OcrKit.Word("(שלום)", 80, 100, 100, 24)]);
        Assert.Equal(new[] { "(שלום)", "סעיף3.14" }.Order(), PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text).Order());
        Assert.Equal("סעיף3.14 (שלום)", TextPage.Create(document, document.Pages[0]).Text.Trim());
    }

    [Fact]
    public void BadWordsAreLeftOut()
    {
        var document = OcrKit.Scan();
        var bad = new List<OcrWord>
        {
            OcrKit.Word("", 10, 10, 50, 20), OcrKit.Word("   ", 10, 40, 50, 20), OcrKit.Word("nan", double.NaN, 10, 50, 20),
            OcrKit.Word("inf", 10, 10, double.PositiveInfinity, 20), OcrKit.Word("flat", 10, 10, 50, 0), OcrKit.Word("back", 10, 10, -50, 20),
            OcrKit.Word("a\u0000b\tc\n", 100, 200, 60, 20), OcrKit.Word("\ud800", 200, 200, 40, 20), OcrKit.Word("outside", -500, 5000, 50, 20),
        };
        Assert.Equal(3, AddWords(document, bad));
        Assert.Equal(new[] { "a b c", "\uFFFD", "outside" }.Order(), PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text).Order());
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.True(PdfOcrLayer.Has(reopened, reopened.Pages[0]));
    }

    [Fact]
    public void WordsPastTheCapAreIgnored()
    {
        var document = OcrKit.Scan();
        var many = Enumerable.Range(0, PdfOcrLayer.MaxWords + 500).Select(i => OcrKit.Word("w" + i, 4 + i % 40 * 9, 4 + i / 40 % 100 * 5, 8, 4)).ToList();
        Assert.Equal(PdfOcrLayer.MaxWords, AddWords(document, many));
    }

    [Fact]
    public void BadArgumentsThrowBeforeAnythingChanges()
    {
        var document = OcrKit.Scan();
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Add(document, [new OcrPageWords(0, OcrKit.Words(), 0, 600)], "en"));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfOcrLayer.Add(document, [new OcrPageWords(0, OcrKit.Words(), 400, 600), new OcrPageWords(3, [], 400, 600)], "en"));
        Assert.False(PdfOcrLayer.Has(document, document.Pages[0]));
        Assert.False(document.HasChanges && OcrKit.LayerStreams(document) > 0);
    }

    [Fact]
    public void LayerOfAnotherToolIsNotFoundOrRemoved()
    {
        var document = OcrKit.Pages("BT 3 Tr /F1 12 Tf 50 500 Td (Other) Tj ET");
        Assert.False(PdfOcrLayer.Has(document, document.Pages[0]));
        Assert.False(PdfOcrLayer.Remove(document, document.Pages[0]));
        Assert.Empty(PdfOcrLayer.Words(document, document.Pages[0]));
        Assert.Null(PdfOcrLayer.Language(document, document.Pages[0]));
    }

    [Fact]
    public void LanguageIsKept()
    {
        var document = OcrKit.Scan();
        PdfOcrLayer.Add(document, [new OcrPageWords(0, OcrKit.Words(), 400, 600)], "tr-TR");
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal("tr-TR", PdfOcrLayer.Language(reopened, reopened.Pages[0]));
    }

    [Fact]
    public void UserUnitAndCropBoxKeepTheBoxes()
    {
        var document = OcrKit.Scan(1, "/CropBox [20 30 380 570] /UserUnit 2");
        var geometry = new PageGeometry(document.Pages[0]);
        Assert.Equal((720, 1080), (geometry.Width, geometry.Height));
        AddWords(document, OcrKit.Words(), 720, 1080);
        OcrKit.AssertAtBoxes(document);
    }
}
