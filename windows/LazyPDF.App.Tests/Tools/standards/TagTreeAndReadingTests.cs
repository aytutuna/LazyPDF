using LazyPDF.App.Tools.Accessibility;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The labels of the tag tree, the reading order lines and what a voice is given, and taking back a half-done edit.
public sealed class TagTreeAndReadingTests
{
    private static string Page(int page) =>
        string.Join("\n\n", Enumerable.Range(0, 12).Select(i => $"Paragraph {i} of page {page} has its own words and numbers {page * 100 + i}."));

    private static PdfDocument Tagged()
    {
        var document = PdfDocument.Open(PdfFromText.Create(Page(1) + "\f" + Page(2), new FakeFonts()).Bytes);
        AutoTagger.Tag(document);
        return PdfDocument.Open(document.SaveIncremental());
    }

    [Fact]
    public void ATagReadsAsItsTypeAndPage()
    {
        var document = Tagged();
        var tree = StructureTree.Read(document)!;
        var paragraph = tree.Elements.First(e => e.Type == "P");

        Assert.Equal("P, page 1", TagLabels.Of(paragraph, tree));
    }

    [Fact]
    public void ADescriptionIsShownBesideTheTagAndCutShort()
    {
        var tree = StructureTree.Create(PdfDocument.Open(Pdfs.Text()));
        var figure = new StructElement("Figure") { Alt = new string('x', 100) };
        tree.Add(null, figure);

        Assert.Equal("Figure: " + new string('x', 60) + "...", TagLabels.Of(figure, tree));
    }

    [Fact]
    public void ACustomTagShowsWhatItMapsTo()
    {
        var tree = StructureTree.Create(PdfDocument.Open(Pdfs.Text()));
        tree.RoleMap["Chapter"] = "H1";
        var element = new StructElement("Chapter");
        tree.Add(null, element);

        Assert.Equal("Chapter (H1)", TagLabels.Of(element, tree));
    }

    [Fact]
    public void TheReadingOrderIsOneLinePerBlockInTagOrder()
    {
        var document = Tagged();

        var lines = ReadingLines.Of(ReadingOrder.Export(document));

        Assert.NotEmpty(lines);
        Assert.Contains(lines, l => l.Contains("Paragraph 5 of page 1"));
        Assert.True(lines.ToList().FindIndex(l => l.Contains("of page 1")) < lines.ToList().FindIndex(l => l.Contains("of page 2")));
    }

    [Fact]
    public void AFileWithoutTagsHasNoReadingOrder() =>
        Assert.Empty(ReadingLines.Of(ReadingOrder.Export(PdfDocument.Open(Pdfs.Text()))));

    [Theory]
    [InlineData("## Chapter two", "Chapter two")]
    [InlineData("[Figure: A grey square]", "Figure: A grey square")]
    [InlineData("Name\tCount\tPrice", "Name,Count,Price")]
    [InlineData("Plain words.", "Plain words.")]
    [InlineData("###", "")]
    public void AVoiceIsGivenTheWordsWithoutTheMarksOfStructure(string line, string spoken) =>
        Assert.Equal(spoken, ReadingLines.Spoken(line));

    [Fact]
    public async Task DiscardingTakesBackAHalfDoneEditAndKeepsTheHistory()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        Pdfs.Retitle(tab.Session, "First");
        tab.Commit("Properties");

        AutoTagger.Tag(tab.Document);
        tab.Session.Discard();

        Assert.False(tab.Commit("Add tags"));
        Assert.False(tab.Document.IsTagged);
        Assert.Equal("First", DocumentMetadata.Read(tab.Document).Title);
        Assert.Equal("Properties", tab.Session.UndoLabel);
    }
}
