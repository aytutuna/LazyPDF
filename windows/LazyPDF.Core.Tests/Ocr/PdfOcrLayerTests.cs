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
    public void SkewedLineIsWrittenWithTurnedTextMatrices()
    {
        var document = OcrKit.Scan();
        double angle = 0.1;
        AddWords(document, [new OcrWord("Skewed", new OcrBox(50, 100, 100, 20), 1f, angle), new OcrWord("line", new OcrBox(160, 100, 60, 20), 1f, angle)]);
        var page = document.Pages[0];
        var matrices = System.Text.RegularExpressions.Regex.Matches(OcrKit.Latin(page.Contents()), @"(\S+) (\S+) (\S+) (\S+) (\S+) (\S+) Tm")
            .Select(m => Enumerable.Range(1, 6).Select(i => double.Parse(m.Groups[i].Value, System.Globalization.CultureInfo.InvariantCulture)).ToArray()).ToList();
        Assert.Equal(3, matrices.Count);
        foreach (var m in matrices)
        {
            Assert.Equal(Math.Cos(angle), m[0], 4);
            Assert.Equal(Math.Sin(angle), m[1], 4);
            Assert.Equal(-Math.Sin(angle), m[2], 4);
            Assert.Equal(Math.Cos(angle), m[3], 4);
        }
        Assert.Equal(50, matrices[0][4], 3);
        Assert.Equal(600 - 120, matrices[0][5], 3);
        Assert.Equal(["Skewed", "line"], TextPage.Create(document, page).Words.Select(w => w.Text));

        var layer = PdfOcrLayer.Words(document, page);
        Assert.Equal(["Skewed", "line"], layer.Select(w => w.Text));
        Assert.Equal(50, layer[0].Box.X, 3);
        Assert.Equal(100, layer[0].Box.Y, 3);
        Assert.Equal(100, layer[0].Box.Width, 3);
        Assert.Equal(20, layer[0].Box.Height, 3);

        PdfOcrLayer.Correct(document, page, 1, "lane");
        Assert.Contains("0.995", OcrKit.Latin(page.Contents()));
        Assert.Equal(["Skewed", "lane"], PdfOcrLayer.Words(document, page).Select(w => w.Text));
    }

    [Fact]
    public void StraightLineIsWrittenAsBefore()
    {
        var a = OcrKit.Scan();
        var b = OcrKit.Scan();
        AddWords(a, [new OcrWord("Same", new OcrBox(50, 100, 100, 20)), new OcrWord("here", new OcrBox(160, 102, 60, 18))]);
        AddWords(b, [new OcrWord("Same", new OcrBox(50, 100, 100, 20), 1f, 0), new OcrWord("here", new OcrBox(160, 102, 60, 18), 1f, double.NaN)]);
        Assert.Equal(OcrKit.Latin(a.Pages[0].Contents()), OcrKit.Latin(b.Pages[0].Contents()));
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

    [Fact]
    public void AddThatCannotAddObjectsLeavesTheOldLayerAlone()
    {
        var document = OcrKit.Scan();
        AddWords(document, OcrKit.Words());
        document.Set(PdfDocument.MaxObjectNumber, PdfNull.Instance);

        Assert.Throws<InvalidOperationException>(() => AddWords(document, [OcrKit.Word("other", 10, 10, 50, 20)]));

        Assert.Equal(["Hello", "world", "Second", "line"], PdfOcrLayer.Words(document, document.Pages[0]).Select(w => w.Text));
        Assert.Equal(1, OcrKit.LayerStreams(document));
    }

    [Fact]
    public void ALayerWithMoreOperationsThanTheFormatCanHoldIsAReadError()
    {
        var document = OcrKit.Scan();
        OcrKit.AddLayer(document, string.Concat(Enumerable.Repeat("BT\n", 8 * PdfOcrLayer.MaxWords + 2)));

        Assert.Throws<PdfReadException>(() => PdfOcrLayer.Words(document, document.Pages[0]));
    }

    [Fact]
    public void ALayerWithMoreWordsThanMaxWordsIsReadUpToMaxWords()
    {
        var document = OcrKit.Scan();
        OcrKit.AddLayer(document, "BT\n/LPOcrF 12 Tf\n" + string.Concat(Enumerable.Repeat("1 0 0 1 0 0 Tm\n<0041> Tj\n", PdfOcrLayer.MaxWords + 1)) + "ET\n");

        Assert.Equal(PdfOcrLayer.MaxWords, PdfOcrLayer.Words(document, document.Pages[0]).Count);
    }

    [Fact]
    public void ALayerStreamThatDoesNotDecodeIsAReadError()
    {
        var document = OcrKit.Scan();
        var marker = new PdfDictionary();
        var dictionary = new PdfDictionary();
        dictionary["LazyPDFOcr"] = marker;
        dictionary["Filter"] = new PdfName("FlateDecode");
        var stream = document.Add(new PdfStream(dictionary, [1, 2, 3, 4, 5]));
        document.Pages[0].Dictionary["Contents"] = new PdfArray([stream]);

        Assert.Throws<PdfReadException>(() => PdfOcrLayer.Words(document, document.Pages[0]));
    }
}
