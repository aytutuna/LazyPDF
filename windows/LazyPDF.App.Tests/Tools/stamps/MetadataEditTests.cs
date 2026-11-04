using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Metadata;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The properties and the opening view written through the tab, so each save is one undo step.
public sealed class MetadataEditTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 30, 0, TimeSpan.Zero);

    private static DocumentTab Open() => new(PdfEditSession.Open(Pdfs.Text()), new FakeRenderer(), null, "a.pdf");

    [Fact]
    public void TheFieldsAndTheViewSurviveACommit()
    {
        using var tab = Open();
        var metadata = DocumentMetadata.Read(tab.Document) with { Title = "Report", Author = "Ayşe Yılmaz", Keywords = "a, b" };
        var view = ViewerSettings.Read(tab.Document) with
        {
            PageMode = PageMode.UseThumbs, PageLayout = PageLayout.TwoPageRight, DisplayDocTitle = true,
            Language = "tr-TR", Duplex = "DuplexFlipLongEdge", NumCopies = 3,
        };

        MetadataEdit.Write(tab.Document, metadata, view, touchModified: false, Now);
        Assert.True(tab.Commit("Properties"));

        var read = DocumentMetadata.Read(tab.Document);
        Assert.Equal("Report", read.Title);
        Assert.Equal("Ayşe Yılmaz", read.Author);
        Assert.Equal("a, b", read.Keywords);
        Assert.Equal(view, ViewerSettings.Read(tab.Document));
    }

    [Fact]
    public void TheChangedDateMovesOnlyWhenAsked()
    {
        using var tab = Open();
        var metadata = DocumentMetadata.Read(tab.Document) with { Title = "A", Modified = Now.AddDays(-30) };
        var view = ViewerSettings.Read(tab.Document);

        MetadataEdit.Write(tab.Document, metadata, view, touchModified: false, Now);
        tab.Commit("Properties");
        Assert.Equal(Now.AddDays(-30), DocumentMetadata.Read(tab.Document).Modified);

        MetadataEdit.Write(tab.Document, metadata with { Title = "B" }, view, touchModified: true, Now);
        tab.Commit("Properties");
        Assert.Equal(Now, DocumentMetadata.Read(tab.Document).Modified);
    }

    [Fact]
    public void ACustomEntryIsLeftAloneByAnEditOfTheTitle()
    {
        using var tab = Open();
        var custom = new Dictionary<string, string> { ["Project"] = "Nile" };
        MetadataEdit.Write(tab.Document, DocumentMetadata.Read(tab.Document) with { Custom = custom }, ViewerSettings.Read(tab.Document), false, Now);
        tab.Commit("Properties");

        MetadataEdit.Write(tab.Document, DocumentMetadata.Read(tab.Document) with { Title = "Nile" }, ViewerSettings.Read(tab.Document), false, Now);
        tab.Commit("Properties");

        Assert.Equal("Nile", DocumentMetadata.Read(tab.Document).Custom["Project"]);
    }

    [Fact]
    public void UndoBringsTheOldValuesBack()
    {
        using var tab = Open();
        var before = DocumentMetadata.Read(tab.Document).Title;

        MetadataEdit.Write(tab.Document, DocumentMetadata.Read(tab.Document) with { Title = "New" }, ViewerSettings.Read(tab.Document), false, Now);
        tab.Commit("Properties");
        tab.Undo();

        Assert.Equal(before, DocumentMetadata.Read(tab.Document).Title);
    }

    [Fact]
    public void EveryChoiceHasWordsAndNoTwoShareThem()
    {
        Assert.Equal(MetadataEdit.Modes.Length, MetadataEdit.Modes.Select(MetadataEdit.ModeName).Distinct().Count());
        Assert.Equal(MetadataEdit.Layouts.Length, MetadataEdit.Layouts.Select(MetadataEdit.LayoutName).Distinct().Count());
        Assert.Equal(MetadataEdit.Sides.Length, MetadataEdit.Sides.Select(MetadataEdit.SidesName).Distinct().Count());
    }
}
