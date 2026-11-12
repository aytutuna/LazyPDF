using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public class BundledFontSourceTests
{
    [Theory]
    [InlineData("Carlito")]
    [InlineData("Caladea")]
    [InlineData("Liberation Sans")]
    [InlineData("Liberation Serif")]
    [InlineData("Liberation Mono")]
    public void ShipsEveryFaceOfTheFamily(string family)
    {
        var source = new BundledFontSource();
        foreach (var style in new[] { FontStyles.Regular, FontStyles.Bold, FontStyles.Italic, FontStyles.Bold | FontStyles.Italic })
        {
            var file = source.Find(family, style);
            Assert.NotNull(file);
            Assert.NotNull(TrueTypeFont.TryParse(file.Data));
        }
    }

    [Theory]
    [InlineData(@"\\host\share\x")]
    [InlineData(@"C:\Windows\Fonts\arial")]
    [InlineData(@"..\Fonts\Carlito")]
    [InlineData("../Carlito")]
    public void PathLikeFamilyGivesNothing(string family)
    {
        Assert.Null(new BundledFontSource().Find(family, FontStyles.Regular));
    }

    [Fact]
    public void UnknownFamilyOrFolderGivesNothing()
    {
        Assert.Null(new BundledFontSource().Find("Comic Sans MS", FontStyles.Regular));
        Assert.Null(new BundledFontSource(Path.Combine(Path.GetTempPath(), "no-such-fonts")).Find("Carlito", FontStyles.Regular));
    }
}
