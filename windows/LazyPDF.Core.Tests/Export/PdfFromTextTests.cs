using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfFromTextTests
{
    private static string PageText(byte[] file, int page)
    {
        using var document = PdfDocument.Open(file);
        return TextPage.Create(document, document.Pages[page]).Text;
    }

    [Fact]
    public void ShortAsciiTextNeedsNoFontSource()
    {
        var made = PdfFromText.Create("Hello\nWorld");
        Assert.Equal(1, made.Pages);
        Assert.Empty(made.Missing);
        Assert.Equal("Hello\nWorld", PageText(made.Bytes, 0));
    }

    [Fact]
    public void LongLinesWrapInsideTheMargin()
    {
        string text = string.Join(" ", Enumerable.Range(0, 150).Select(i => "word" + i));
        var made = PdfFromText.Create(text, setup: new PdfPageSetup(Margin: 72));
        using var document = PdfDocument.Open(made.Bytes);
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[0], recorder);
        Assert.All(recorder.Glyphs, g =>
        {
            Assert.InRange(g.Bounds.Left, 71.9, 595.276 - 72 + 0.1);
            Assert.InRange(g.Bounds.Right, 71.9, 595.276 - 72 + 0.1);
        });
        var lines = PageText(made.Bytes, 0).Split('\n');
        Assert.True(lines.Length > 3);
        Assert.Equal(text, string.Join(" ", lines));
    }

    [Fact]
    public void ManyLinesFlowOntoMorePages()
    {
        string text = string.Join("\n", Enumerable.Range(1, 200).Select(i => $"line {i}"));
        var made = PdfFromText.Create(text);
        // 841.89 - 72 points of room at 11 pt Arial-class metrics.
        Assert.InRange(made.Pages, 4, 6);
        string all = string.Join("\n", Enumerable.Range(0, made.Pages).Select(i => PageText(made.Bytes, i)));
        Assert.Equal(text, all);
    }

    [Fact]
    public void AFormFeedStartsAPageAndATrailingOneAddsNone()
    {
        Assert.Equal(3, PdfFromText.Create("one\ftwo\fthree").Pages);
        var made = PdfFromText.Create("one\ftwo\f");
        Assert.Equal(2, made.Pages);
        Assert.Equal("two", PageText(made.Bytes, 1));
    }

    [Fact]
    public void TabsAreFourSpacesAndOtherControlCharactersGoAway()
    {
        var made = PdfFromText.Create("a\tb\u0001c\r\nd");
        Assert.Equal("a    bc\nd", PageText(made.Bytes, 0));
    }

    [Fact]
    public void AnEmptyTextIsOneBlankPage()
    {
        var made = PdfFromText.Create("");
        Assert.Equal(1, made.Pages);
        Assert.Equal("", PageText(made.Bytes, 0));
    }

    [Fact]
    public void AWordWiderThanTheLineBreaksWithinIt()
    {
        string word = new('x', 400);
        var made = PdfFromText.Create(word);
        Assert.Equal(word, PageText(made.Bytes, 0).Replace("\n", ""));
    }

    [Fact]
    public void LetterAndLandscapeSetThePage()
    {
        using var document = PdfDocument.Open(PdfFromText.Create("x", setup: new PdfPageSetup(PdfPaper.Letter, PdfOrientation.Landscape)).Bytes);
        Assert.Equal((792, 612), (document.Pages[0].MediaBox.Width, document.Pages[0].MediaBox.Height));
    }

    [Theory]
    [InlineData(PdfPaper.A3, 841.89, 1190.551)]
    [InlineData(PdfPaper.A5, 419.528, 595.276)]
    [InlineData(PdfPaper.Legal, 612, 1008)]
    public void NamedPapersSetThePage(PdfPaper paper, double width, double height)
    {
        using var document = PdfDocument.Open(PdfFromText.Create("x", setup: new PdfPageSetup(paper)).Bytes);
        Assert.Equal((width, height), (document.Pages[0].MediaBox.Width, document.Pages[0].MediaBox.Height));
    }

    [Fact]
    public void CustomPaperTurnsWhenLandscape()
    {
        var setup = new PdfPageSetup(PdfPaper.Custom, PdfOrientation.Landscape, 1, 200, 300);
        using var document = PdfDocument.Open(PdfFromText.Create("x", setup: setup).Bytes);
        Assert.Equal((300, 200), (document.Pages[0].MediaBox.Width, document.Pages[0].MediaBox.Height));
    }

    [Fact]
    public void TurkishTextIsEmbeddedAndReadsBack()
    {
        const string turkish = "Çağrı Öztürk şirketi İstanbul'da, ığdır ve Şanlıurfa'ya gitti.\nĞÜŞİÖÇ ğüşıöç";
        var made = PdfFromText.Create(turkish, new ExportArialSource());
        Assert.Empty(made.Missing);
        Assert.Equal(turkish, PageText(made.Bytes, 0));
        using var pig = PigDocument.Open(made.Bytes);
        Assert.Equal(turkish.Replace("\n", " "), string.Join(" ", pig.GetPage(1).GetWords().Select(w => w.Text)).Replace("  ", " "));
        using var document = PdfDocument.Open(made.Bytes);
        var font = PdfFont.Get(document, (PdfDictionary)document.Resolve(((PdfDictionary)document.Resolve(document.Pages[0].Resources!["Font"])!)["F1"])!);
        Assert.True(font.IsEmbedded);
    }

    [Fact]
    public void TurkishWithoutAFontFileIsRefused()
    {
        var error = Assert.Throws<InvalidOperationException>(() => PdfFromText.Create("ğüşıİ"));
        Assert.Equal(ExportText.NoFont, error.Message);
    }

    [Fact]
    public void CharactersTheFontLacksAreReported()
    {
        var made = PdfFromText.Create("abc 中", new ExportArialSource());
        Assert.Equal([0x4e2d], made.Missing);
    }

    [Fact]
    public void ARoomLessPageIsRefused()
    {
        Assert.Throws<ArgumentException>(() => PdfFromText.Create("x", setup: new PdfPageSetup(Margin: 400)));
        Assert.Throws<ArgumentException>(() => PdfFromText.Create("x", setup: new PdfPageSetup(Margin: -5)));
        Assert.Throws<ArgumentException>(() => PdfFromText.Create("x", size: 0));
    }

    [Fact]
    public void ACancelledTokenStopsTheMakingOfThePdf()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => PdfFromText.Create("Hello\fWorld", cancellation: source.Token));
    }

    [Fact]
    public void ACancelDuringTheFontLookupStopsBeforeThePages()
    {
        using var source = new CancellationTokenSource();
        var fonts = new CancellingFonts(source);
        Assert.Throws<OperationCanceledException>(() => PdfFromText.Create("Çağrı\fŞanlıurfa", fonts, cancellation: source.Token));
        Assert.Equal(1, fonts.Asked);
    }

    private sealed class CancellingFonts(CancellationTokenSource source) : IFontSource
    {
        public int Asked { get; private set; }

        public FontFile? Find(string family, FontStyles style)
        {
            Asked++;
            source.Cancel();
            return new ExportArialSource().Find(family, style);
        }
    }}
