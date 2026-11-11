using LazyPDF.App.Tools.Metadata;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Metadata;

public sealed class MetadataEditTests
{
    private static DocumentMetadata Blank() => DocumentMetadata.Read(PdfDocument.Open(Pdfs.Text(1)));

    [Theory]
    [InlineData("Old", null, true)]
    [InlineData("Old", "New", true)]
    [InlineData("Old", "Old", false)]
    [InlineData(null, "New", false)]
    [InlineData("", "New", false)]
    public void OnlyAnEarlierTextThatChangesCounts(string? before, string? after, bool expected)
    {
        var start = Blank() with { Author = before };
        Assert.Equal(expected, MetadataEdit.DropsText(start, start with { Author = after }));
    }

    [Fact]
    public void OtherFieldsDoNotCount()
    {
        var start = Blank() with { Creator = "A" };
        Assert.False(MetadataEdit.DropsText(start, start with { Creator = "B" }));
    }
}
