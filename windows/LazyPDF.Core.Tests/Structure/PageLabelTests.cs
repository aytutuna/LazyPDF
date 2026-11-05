using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageLabelTests
{
    private static IReadOnlyList<string> Labels(int pages, params PageLabelRange[] ranges) =>
        [.. Enumerable.Range(0, pages).Select(i => PdfPageLabels.Label(ranges, i))];

    [Fact]
    public void NoRangesNumberPagesFromOne()
    {
        Assert.Equal(["1", "2", "3"], Labels(3));
    }

    [Fact]
    public void RomanFrontMatterThenDecimalWithPrefix()
    {
        var labels = Labels(8, new(0, PageLabelStyle.LowerRoman), new(3, PageLabelStyle.Decimal), new(6, PageLabelStyle.Decimal, "A-", 10));
        Assert.Equal(["i", "ii", "iii", "1", "2", "3", "A-10", "A-11"], labels);
    }

    [Theory]
    [InlineData(1, "I")]
    [InlineData(4, "IV")]
    [InlineData(9, "IX")]
    [InlineData(14, "XIV")]
    [InlineData(40, "XL")]
    [InlineData(94, "XCIV")]
    [InlineData(1994, "MCMXCIV")]
    [InlineData(3999, "MMMCMXCIX")]
    public void UpperRoman(int number, string expected)
    {
        Assert.Equal(expected, PdfPageLabels.Label([new PageLabelRange(0, PageLabelStyle.UpperRoman, "", number)], 0));
    }

    [Theory]
    [InlineData(1, "a")]
    [InlineData(26, "z")]
    [InlineData(27, "aa")]
    [InlineData(28, "bb")]
    [InlineData(52, "zz")]
    [InlineData(53, "aaa")]
    public void LowerLetters(int number, string expected)
    {
        Assert.Equal(expected, PdfPageLabels.Label([new PageLabelRange(0, PageLabelStyle.LowerLetters, "", number)], 0));
        Assert.Equal(expected.ToUpperInvariant(), PdfPageLabels.Label([new PageLabelRange(0, PageLabelStyle.UpperLetters, "", number)], 0));
    }

    [Fact]
    public void PrefixOnlyRange()
    {
        Assert.Equal(["Cover", "Cover", "1"], Labels(3, new(0, PageLabelStyle.None, "Cover"), new(2)));
    }

    [Fact]
    public void RangeBeforeFirstStartFallsBackToDecimal()
    {
        Assert.Equal(["1", "2", "x"], Labels(3, new PageLabelRange(2, PageLabelStyle.None, "x")));
    }

    [Fact]
    public void ReadsHandWrittenLabels()
    {
        var document = StructureFixtures.File("/PageLabels <</Nums [0 <</S /r>> 1 <</S /D /P (p. ) /St 5>> 2 <</S /Q>>]>>");
        var ranges = PdfPageLabels.Read(document);
        Assert.Equal([PageLabelStyle.LowerRoman, PageLabelStyle.Decimal, PageLabelStyle.None], ranges.Select(r => r.Style));
        Assert.Equal(["i", "p. 5", ""], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void ReadIgnoresJunk()
    {
        var document = StructureFixtures.File("/PageLabels <</Nums [-3 <</S /D>> 0 5 1 <</S /D /St 0>> 2 <</S /D /St -4>>]>>");
        var ranges = PdfPageLabels.Read(document);
        Assert.Equal([1, 2], ranges.Select(r => r.StartPage));
        Assert.Equal([1, 1], ranges.Select(r => r.FirstNumber));
    }

    [Fact]
    public void WriteSortsAndAddsRangeAtZero()
    {
        var document = StructureFixtures.Open(6);
        PdfPageLabels.Write(document, [new(4, PageLabelStyle.UpperLetters), new(2, PageLabelStyle.Decimal, "S", 3), new(2, PageLabelStyle.Decimal, "T", 3)]);
        var reopened = StructureFixtures.Reopen(document);
        var ranges = PdfPageLabels.Read(reopened);
        Assert.Equal([0, 2, 4], ranges.Select(r => r.StartPage));
        Assert.Equal(["1", "2", "T3", "T4", "A", "B"], PdfPageLabels.Labels(reopened));
    }

    [Fact]
    public void WriteReplacesAndRemoves()
    {
        var document = StructureFixtures.Open(3);
        PdfPageLabels.Write(document, [new(0, PageLabelStyle.LowerRoman)]);
        PdfPageLabels.Write(document, [new(0, PageLabelStyle.UpperRoman), new(1)]);
        Assert.Equal(["I", "1", "2"], PdfPageLabels.Labels(document));
        PdfPageLabels.Write(document, []);
        Assert.Null(document.Catalog["PageLabels"]);
        Assert.Equal(["1", "2", "3"], PdfPageLabels.Labels(document));
    }

    [Fact]
    public void ManyRangesBecomeATree()
    {
        var document = StructureFixtures.Open(500);
        PdfPageLabels.Write(document, Enumerable.Range(0, 500).Select(i => new PageLabelRange(i, PageLabelStyle.Decimal, $"s{i}-")));
        var reopened = StructureFixtures.Reopen(document);
        Assert.Equal("s499-1", PdfPageLabels.Labels(reopened)[499]);
        Assert.NotNull(reopened.Dict(reopened.Catalog, "PageLabels")!["Kids"]);
    }

    [Fact]
    public void WrittenLabelsWithNonLatinPrefix()
    {
        var document = StructureFixtures.Open(2);
        PdfPageLabels.Write(document, [new(0, PageLabelStyle.Decimal, "Ж-")]);
        Assert.Equal("Ж-2", PdfPageLabels.Labels(StructureFixtures.Reopen(document))[1]);
    }

    [Fact]
    public void FindsAPageByLabel()
    {
        var document = StructureFixtures.Open(6);
        PdfPageLabels.Write(document, [new(0, PageLabelStyle.LowerRoman), new(2, PageLabelStyle.Decimal)]);
        Assert.Equal(1, PdfPageLabels.Find(document, "ii"));
        Assert.Equal(1, PdfPageLabels.Find(document, "II"));
        Assert.Equal(5, PdfPageLabels.Find(document, "4"));
        Assert.Null(PdfPageLabels.Find(document, "zz"));
    }

    [Fact]
    public void FindComparesOrdinally()
    {
        var document = StructureFixtures.Open(3);
        PdfPageLabels.Write(document, [new(0, PageLabelStyle.None, "Kısım"), new(1, PageLabelStyle.None, "ᾀ"), new(2, PageLabelStyle.None, "é")]);
        Assert.Null(PdfPageLabels.Find(document, "KISIM"));
        Assert.Equal(0, PdfPageLabels.Find(document, "KıSıM"));
        Assert.Equal(1, PdfPageLabels.Find(document, "ᾈ"));
        Assert.Equal(2, PdfPageLabels.Find(document, "É"));
        Assert.Null(PdfPageLabels.Find(document, "é"));
    }
}
