using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class BatesTests
{
    private static HeaderFooterSpec Footer(BatesSpec bates, IReadOnlyList<int>? pages = null) =>
        new() { Footer = new("", "", "{bates}"), Bates = bates, Pages = pages };

    private static string Shown(PdfDocument document, int page) => StampKit.Text(StampKit.Glyphs(document, page));

    [Fact]
    public void NumbersHavePrefixSuffixAndDigits()
    {
        var bates = new BatesSpec("ACME-", "/A", 5, 41);
        Assert.Equal("ACME-00041/A", bates.Format(41));
        Assert.Equal("ACME-123456/A", bates.Format(123456));
        Assert.Equal("7", new BatesSpec(Digits: 0).Format(7));
    }

    [Fact]
    public void ABatchContinuesFromTheNextNumberReturned()
    {
        var first = StampKit.Doc(3);
        var second = StampKit.Doc(2);
        var one = new PdfStamper(first).AddHeaderFooter(Footer(new BatesSpec("DOC", "", 4, 1)));
        Assert.Equal(4, one.NextBates);
        var two = new PdfStamper(second).AddHeaderFooter(Footer(new BatesSpec("DOC", "", 4, one.NextBates)));
        Assert.Equal(6, two.NextBates);

        Assert.Equal("DOC0001", Shown(first, 0));
        Assert.Equal("DOC0003", Shown(first, 2));
        Assert.Equal("DOC0004", Shown(second, 0));
        Assert.Equal("DOC0005", Shown(second, 1));
    }

    [Fact]
    public void OnlyStampedPagesUseUpNumbers()
    {
        var document = StampKit.Doc(4);
        var run = new PdfStamper(document).AddHeaderFooter(Footer(new BatesSpec(Start: 10), [3, 1]));
        Assert.Equal(12, run.NextBates);
        Assert.Equal("000010", Shown(document, 1));
        Assert.Equal("000011", Shown(document, 3));
    }

    [Fact]
    public void ABatesRunIsListedAsOneAndSurvivesSaving()
    {
        var document = StampKit.Doc(2);
        new PdfStamper(document).AddHeaderFooter(Footer(new BatesSpec("X-", "", 3, 1)));
        var file = StampKit.Rewrite(document);
        Assert.Contains("X-002", StampKit.PigText(file, 2));
        using var reopened = PdfDocument.Open(file);
        Assert.Equal(StampKind.Bates, Assert.Single(new PdfStamper(reopened).List()).Kind);
    }

    [Fact]
    public void WithoutASpecTheTokenIsLeftAndNoNumberIsReturned()
    {
        var document = StampKit.Doc(1);
        var run = new PdfStamper(document).AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "", "{bates}") });
        Assert.Equal(0, run.NextBates);
        Assert.Equal("{bates}", Shown(document, 0));
    }
}
