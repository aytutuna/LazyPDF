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

    private static DocumentMetadata WithCustom(params (string, string)[] pairs) =>
        Blank() with { Custom = pairs.ToDictionary(p => p.Item1, p => p.Item2) };

    [Fact]
    public void SameIgnoresOrderAndSeesAChangedValue()
    {
        var a = WithCustom(("A", "1"), ("B", "2"));
        Assert.True(MetadataEdit.Same(a, WithCustom(("B", "2"), ("A", "1"))));
        Assert.False(MetadataEdit.Same(a, WithCustom(("A", "1"), ("B", "3"))));
        Assert.False(MetadataEdit.Same(a, a with { Title = "T" }));
    }

    [Fact]
    public void ARemovedOrChangedCustomValueDrops()
    {
        var start = WithCustom(("A", "1"));
        Assert.True(MetadataEdit.DropsText(start, WithCustom()));
        Assert.True(MetadataEdit.DropsText(start, WithCustom(("A", "2"))));
        Assert.False(MetadataEdit.DropsText(start, WithCustom(("A", "1"), ("B", "2"))));
    }

    [Fact]
    public void ACustomKeyRoundTripsThroughTheFile()
    {
        var document = PdfDocument.Open(Pdfs.Text(1));
        MetadataEdit.Write(document, WithCustom(("Project", "Blue")), ViewerSettings.Read(document), false, DateTimeOffset.Now);
        var reread = DocumentMetadata.Read(PdfDocument.Open(document.SaveRewrite()));
        Assert.Equal("Blue", reread.Custom["Project"]);
    }

    [Fact]
    public void ProblemsWithTheRows()
    {
        Assert.Null(MetadataEdit.CustomProblem([("A", "1"), (" ", "")]));
        Assert.NotNull(MetadataEdit.CustomProblem([("Title", "1")]));
        Assert.NotNull(MetadataEdit.CustomProblem([("A", "1"), (" A ", "2")]));
        Assert.Null(MetadataEdit.CustomProblem([("A", "")]));
        Assert.NotNull(MetadataEdit.CustomProblem([("Müşteri", "1")]));
        Assert.Null(MetadataEdit.CustomProblem([("Project-1", "1")]));
        Assert.NotNull(MetadataEdit.CustomNote([("A", "")]));
        Assert.Equal("2", MetadataEdit.Custom([("A", "1"), ("A ", "2"), ("B", "")])["A"]);
        Assert.Single(MetadataEdit.Custom([("A", "1"), ("A ", "2"), ("B", "")]));
    }
}
