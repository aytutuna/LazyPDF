using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class LazyPdfAddressTests
{
    [Theory]
    [InlineData("lazypdf:", true)]
    [InlineData("LazyPDF://open?file=x", true)]
    [InlineData("  lazypdf:open", true)]
    [InlineData("lazyprint:open", false)]
    [InlineData(@"C:\docs\lazypdf.pdf", false)]
    public void OnlyTheOwnSchemeIsAnAddress(string text, bool expected) =>
        Assert.Equal(expected, LazyPdfAddress.IsAddress(text));

    [Fact]
    public void AnAddressWithNoFileJustBringsTheWindowForward()
    {
        Assert.Empty(LazyPdfAddress.Parse("lazypdf:"));
        Assert.Empty(LazyPdfAddress.Parse("lazypdf://open"));
    }

    [Fact]
    public void FilesAreUnescapedAndKeptInOrder()
    {
        var files = LazyPdfAddress.Parse("lazypdf://open?file=C%3A%5Cdocs%5Ca%20b.pdf&file=D%3A%5Cc.pdf");

        Assert.Equal([@"C:\docs\a b.pdf", @"D:\c.pdf"], files);
    }

    [Fact]
    public void ARelativePathIsNotAFile()
    {
        Assert.Empty(LazyPdfAddress.Parse("lazypdf://open?file=docs%5Ca.pdf&file=a.pdf"));
    }

    [Fact]
    public void OtherParametersAreIgnored()
    {
        Assert.Equal([@"C:\a.pdf"], LazyPdfAddress.Parse("lazypdf://open?x=1&file=C%3A%5Ca.pdf&y"));
    }
}
