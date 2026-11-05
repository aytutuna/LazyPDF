using System.Globalization;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class HeaderFooterTests
{
    private static readonly DateTimeOffset Day = new(2026, 3, 9, 10, 0, 0, TimeSpan.Zero);

    private static string Shown(PdfDocument document, int page) => StampKit.Text(StampKit.Glyphs(document, page));

    [Fact]
    public void TheSixSlotsSitInTheirCornersAndCentres()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec
        {
            Header = new("HL", "HC", "HR"),
            Footer = new("FL", "FC", "FR"),
            FontSize = 10,
            MarginX = 30,
            MarginTop = 20,
            MarginBottom = 25,
        });
        var glyphs = StampKit.Glyphs(document, 0);
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Regular, ["HLFRC"])!;
        var header = glyphs.Where(g => g.Y < 100).ToList();
        var footer = glyphs.Where(g => g.Y > 200).ToList();

        Assert.Equal("HLHCHR", StampKit.Text(header));
        Assert.Equal(20 + font.Ascent * 10, header[0].Y, 3);
        Assert.Equal(30, header[0].X, 3);
        Assert.Equal(100 - font.Width("HC", 10) / 2, header[2].X, 3);
        Assert.Equal(200 - 30 - font.Width("HR", 10), header[4].X, 3);
        Assert.Equal("FLFCFR", StampKit.Text(footer));
        Assert.Equal(300 - 25 + font.Descent * 10, footer[0].Y, 3);
        Assert.Equal(30, footer[0].X, 3);
    }

    [Fact]
    public void PageNumbersCountFromTheStartNumber()
    {
        var document = StampKit.Doc(3);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "Page {page} of {pages}", ""), StartNumber = 5 });
        Assert.Equal("Page 5 of 7", Shown(document, 0));
        Assert.Equal("Page 7 of 7", Shown(document, 2));
    }

    [Fact]
    public void ANumberPastTheEndOfAnIntWraps()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "{page} of {pages}", ""), StartNumber = int.MaxValue });
        Assert.Equal("2147483647 of -2147483648", Shown(document, 0));
        Assert.Equal("-2147483648 of -2147483648", Shown(document, 1));
    }

    [Fact]
    public void DateFileAndTheDefaultFormat()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec
        {
            Header = new("{date}", "{file}", "{date:dd/MM/yyyy}"),
            Date = Day,
            FileName = "report.pdf",
        });
        Assert.Equal("2026-03-09report.pdf09/03/2026", Shown(document, 0));
    }

    [Fact]
    public void ADateFormatFollowsTheCulture()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec
        {
            Header = new("", "{date:d MMMM yyyy}", ""),
            Date = Day,
            Culture = new CultureInfo("en-GB"),
        });
        Assert.Equal("9 March 2026", Shown(document, 0));
    }

    [Fact]
    public void UnknownTokensAndBracesStayAsTyped()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Header = new("", "{nope} {page", "{bates}") });
        Assert.Equal("{nope} {page{bates}", Shown(document, 0));
    }

    [Fact]
    public void EvenPagesCanDifferFromOddOnes()
    {
        var document = StampKit.Doc(3);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec
        {
            Header = new("", "", "odd"),
            EvenHeader = new("even", "", ""),
            Footer = new("", "{page}", ""),
        });
        Assert.Equal("odd1", Shown(document, 0));
        Assert.Equal("even2", Shown(document, 1));
        Assert.Equal("odd3", Shown(document, 2));
        Assert.Equal(36, StampKit.Glyphs(document, 1)[0].X, 3);
    }

    [Fact]
    public void AnEvenFooterAloneKeepsTheHeader()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Header = new("H", "", ""), Footer = new("", "", "odd"), EvenFooter = new("", "", "even") });
        Assert.Equal("Hodd", Shown(document, 0));
        Assert.Equal("Heven", Shown(document, 1));
    }

    [Fact]
    public void OnlyTheChosenPagesAreStamped()
    {
        var document = StampKit.Doc(4);
        var run = new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "{page}", ""), Pages = [1, 3] });
        Assert.Equal(2, run.Pages);
        Assert.Equal("", Shown(document, 0));
        Assert.Equal("2", Shown(document, 1));
        Assert.Equal("4", Shown(document, 3));
    }

    [Fact]
    public void PagesWithNothingToShowAreSkipped()
    {
        var document = StampKit.Doc(2);
        var run = new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Header = new("", "", "x"), EvenHeader = new() });
        Assert.Equal(1, run.Pages);
        Assert.Empty(new PdfStamper(document).List(document.Pages[1]));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void RotatedPagesKeepTheTextUprightAndInPlace(int rotate)
    {
        var document = StampKit.Pages(($"/Rotate {rotate}", "BT /F1 12 Tf 50 50 Td (p) Tj ET"));
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Header = new("", "AB", ""), Footer = new("CD", "", "") });
        var geometry = new PageGeometry(document.Pages[0]);
        var glyphs = StampKit.Glyphs(document, 0);
        Assert.All(glyphs, g =>
        {
            Assert.Equal(1, g.DirX, 6);
            Assert.Equal(0, g.DirY, 6);
        });
        var head = glyphs.Where(g => g.Text is "A" or "B").ToList();
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Regular, ["AB"])!;
        Assert.Equal(head[0].Y, head[1].Y, 6);
        Assert.True(head[0].Y < 60);
        Assert.Equal(geometry.Width / 2 - font.Width("AB", 10) / 2, head[0].X, 3);
        var foot = glyphs.First(g => g.Text == "C");
        Assert.True(foot.Y > geometry.Height - 60);
        Assert.Equal(36, foot.X, 3);
    }

    [Fact]
    public void TurkishTextNeedsAndGetsAnEmbeddedFont()
    {
        var document = StampKit.Doc(2);
        const string text = "Sayfa şiirİ {page}";
        Assert.Throws<InvalidOperationException>(() => new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", text, "") }));
        var run = new PdfStamper(document, new ArialSource()).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", text, "") });
        Assert.Empty(run.Missing);
        using var reopened = PdfDocument.Open(StampKit.Rewrite(document));
        Assert.Equal("Sayfa şiirİ 2", Shown(reopened, 1));
    }

    [Fact]
    public void ColourSizeAndStyleAreUsed()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec
        {
            Header = new("", "x", ""),
            Color = new StampColor(1, 0, 0),
            FontSize = 18,
            FontStyle = FontStyles.Bold,
        });
        Assert.Equal(18, StampKit.Glyphs(document, 0)[0].Size, 6);
        Assert.Contains("1 0 0 rg", StampKit.Latin(document, 0));
        var font = document.Dict(document.Dict(document.Pages[0].Resources, "Font"), "LPS1_F")!;
        Assert.Equal("Helvetica-Bold", document.Name(font, "BaseFont"));
    }

    [Fact]
    public void UserUnitScalesTheMarginsAndTextBackToPoints()
    {
        var document = StampKit.Pages(("/UserUnit 2", "BT /F1 12 Tf 50 50 Td (u) Tj ET"));
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Header = new("W", "", ""), MarginX = 20 });
        var glyph = StampKit.Glyphs(document, 0)[0];
        Assert.Equal(20, glyph.X, 3);
        Assert.Equal(10, glyph.Size, 6);
    }

    [Fact]
    public void ACropBoxIsTheEdgeOfThePage()
    {
        var document = StampKit.Pages(("/CropBox [10 20 110 220]", "BT /F1 12 Tf 50 50 Td (c) Tj ET"));
        new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("L", "", "R"), MarginX = 15, MarginBottom = 10 });
        var glyphs = StampKit.Glyphs(document, 0);
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Regular, ["LR"])!;
        Assert.Equal(15, glyphs[0].X, 3);
        Assert.Equal(100 - 15 - font.Width("R", 10), glyphs[1].X, 3);
        Assert.Equal(200 - 10 + font.Descent * 10, glyphs[0].Y, 3);
    }
}
