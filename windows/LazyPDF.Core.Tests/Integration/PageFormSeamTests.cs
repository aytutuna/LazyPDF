using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageFormSeamTests
{
    [Fact]
    public void DeletingAPageTakesItsWidgetsOutOfTheForm()
    {
        var session = PdfEditSession.Open(IntegrationFiles.Form(3));
        var form = PdfForm.Read(session.Document);
        form.SetValues(new Dictionary<string, string?> { ["f1"] = "one", ["f2"] = "two", ["f3"] = "three" });

        PageOperations.Delete(session.Document, [0]);
        Assert.True(session.Commit("delete"));

        var document = IntegrationFiles.Reopen(session);
        var after = PdfForm.Read(document);
        Assert.Null(after.Find("f1"));
        Assert.Null(after.Find("agree"));
        Assert.Equal("two", after.Find("f2")!.Value);
        Assert.Equal("three", after.Find("f3")!.Value);
        Assert.Empty(after.Orphans);
        Assert.All(after.Fields.SelectMany(f => f.Widgets), w => Assert.True(w.PageIndex >= 0));
    }

    [Fact]
    public void DeletedPageLeavesNoFieldValueInTheRewrittenFile()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(2));
        PdfForm.Read(document).SetValue("f1", "needle-on-page-one");
        PageOperations.Delete(document, [0]);

        var text = System.Text.Encoding.Latin1.GetString(document.SaveRewrite());
        Assert.DoesNotContain("needle-on-page-one", text);
        Assert.DoesNotContain("Page 1 body", text);
    }

    [Fact]
    public void MergedFormsKeepTheirValuesApart()
    {
        var first = PdfDocument.Open(IntegrationFiles.Form(2));
        var second = PdfDocument.Open(IntegrationFiles.Form(2));
        PdfForm.Read(first).SetValue("f1", "from first");
        PdfForm.Read(second).SetValue("f1", "from second");

        var merged = PageAssembly.Merge([new MergeSource(first), new MergeSource(second)]);
        var bytes = merged.SaveRewrite();
        var texts = IntegrationFiles.ReadBack(bytes);
        Assert.Equal(4, texts.Count);

        var form = PdfForm.Read(PdfDocument.Open(bytes));
        var names = form.Fields.Select(f => f.Name).ToList();
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.Equal("from first", form.Find("f1")!.Value);
        Assert.Equal("from second", form.Find("f1_2")!.Value);
        Assert.Equal(2, form.Find("f1_2")!.Widgets[0].PageIndex);

        form.SetValue("f1_2", "changed");
        Assert.Equal("from first", form.Find("f1")!.Value);
    }

    [Fact]
    public void MergeThenFillThenFlattenLeavesTheTextOnly()
    {
        var merged = PageAssembly.Merge([
            new MergeSource(PdfDocument.Open(IntegrationFiles.Form(1))),
            new MergeSource(PdfDocument.Open(IntegrationFiles.Form(1)))]);
        var form = PdfForm.Read(merged);
        form.SetValues(new Dictionary<string, string?> { ["f1"] = "alpha", ["f1_2"] = "beta" });
        form.Flatten();

        var texts = IntegrationFiles.ReadBack(merged.SaveRewrite());
        Assert.Contains("alpha", texts[0]);
        Assert.Contains("beta", texts[1]);
        Assert.Empty(PdfForm.Read(merged).Fields);
    }

    [Fact]
    public void SplittingAtBookmarksGivesOnePartPerChapter()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(6, bookmarks: [0, 2, 5]));
        var outline = Outline.Read(document);
        var starts = outline.Items.Select(i => i.Destination!.PageIndex).ToList();
        Assert.Equal([0, 2, 5], starts);

        var parts = PageAssembly.SplitAt(document, starts);
        Assert.Equal([2, 3, 1], parts.Select(p => p.Pages.Count));

        var middle = parts[1].SaveRewrite();
        var texts = IntegrationFiles.ReadBack(middle);
        Assert.Contains("Page 3", texts[0]);
        Assert.Contains("Page 5", texts[2]);

        var form = PdfForm.Read(PdfDocument.Open(middle));
        Assert.Equal(["f3", "f4", "f5"], form.Fields.Select(f => f.Name));
        Assert.Null(form.Find("agree"));
        Assert.Empty(Outline.Read(PdfDocument.Open(middle)).Items);
    }

    [Fact]
    public void OutlineSurvivesDeletingAnotherChapter()
    {
        var session = PdfEditSession.Open(IntegrationFiles.Form(4, bookmarks: [0, 2]));
        PageOperations.Delete(session.Document, [0, 1]);
        Assert.True(session.Commit("delete"));

        var outline = Outline.Read(IntegrationFiles.Reopen(session));
        Assert.Equal(["Chapter 1", "Chapter 2"], outline.Items.Select(i => i.Title));
        Assert.Null(outline.Items[0].Destination);
        Assert.Equal(0, outline.Items[1].Destination!.PageIndex);
    }

    [Fact]
    public void ExtractedPageBringsItsFieldsAndAnnotations()
    {
        var source = PdfDocument.Open(IntegrationFiles.Form(3));
        new PdfAnnotationWriter(source).AddTextMarkup(source.Pages[1], AnnotationType.Highlight,
            [MarkupQuad.FromRect(new PdfRect(40, 495, 200, 515))], new AnnotationInfo("a", "hi"));
        PdfForm.Read(source).SetValue("f2", "kept");

        var part = PageAssembly.Extract(source, [1]);
        var bytes = part.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);
        var again = PdfDocument.Open(bytes);
        Assert.Equal("kept", PdfForm.Read(again).Find("f2")!.Value);
        Assert.Contains(PdfAnnotations.Read(again, again.Pages[0]), a => a.Type == AnnotationType.Highlight);
    }
}
