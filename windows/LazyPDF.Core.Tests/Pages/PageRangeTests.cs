using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The cases of Lazy Print's PageRangeTests.cs: "1-3, 5, 8-" means the same in all three apps.

public class PageRangeTests
{
    [Fact]
    public void Parse_PagesAndRanges_GivesZeroBasedIndices()
    {
        var result = PageRange.Parse("1-3, 5, 8-", 10);
        Assert.True(result.IsSuccess);
        Assert.Equal([0, 1, 2, 4, 7, 8, 9], result.Pages);
    }

    [Fact]
    public void Parse_OrderTypedAndRepeats_AreKept()
    {
        Assert.Equal([4, 0, 1, 1, 0], PageRange.Parse("5,1-2,2,1", 8).Pages);
    }

    [Fact]
    public void Parse_SpacesAroundNumbersAndDashes_AreIgnored()
    {
        Assert.Equal([1, 2, 3, 6], PageRange.Parse(" 2 - 4 ,  7 ", 8).Pages);
    }

    [Fact]
    public void Parse_OpenRangeAtTheLastPage_IsThatPage()
    {
        Assert.Equal([7], PageRange.Parse("8-", 8).Pages);
    }

    [Fact]
    public void Parse_WholeDocument_IsEveryPage()
    {
        Assert.Equal([0, 1, 2], PageRange.Parse("1-3", 3).Pages);
    }

    [Theory]
    [InlineData("9", 8, "Page 9 is past the end (8 pages)")]
    [InlineData("1-12", 8, "Page 12 is past the end (8 pages)")]
    [InlineData("9-", 8, "Page 9 is past the end (8 pages)")]
    [InlineData("2, 3", 1, "Page 2 is past the end (1 page)")]
    [InlineData("1", 0, "Page 1 is past the end (0 pages)")]
    public void Parse_PastTheEnd_NamesThePage(string text, int pageCount, string message)
    {
        var result = PageRange.Parse(text, pageCount);
        Assert.False(result.IsSuccess);
        Assert.Empty(result.Pages);
        Assert.Equal(message, result.Error!.Message);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("abc")]
    [InlineData("1,,2")]
    [InlineData("1,")]
    [InlineData("3-1")]
    [InlineData("0")]
    [InlineData("0-2")]
    [InlineData("-3")]
    [InlineData("1-2-3")]
    [InlineData("1.5")]
    [InlineData("1 2")]
    [InlineData("99999999999")]
    public void Parse_NotPages_ExplainsTheFormat(string text)
    {
        var result = PageRange.Parse(text, 8);
        Assert.False(result.IsSuccess);
        Assert.Equal("Type pages like 1-3, 5", result.Error!.Message);
    }
}
