using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OutlineTests
{
    // Chapter 1 (open) has two children, chapter 2 (closed) has one, chapter 3 has none. The counts are
    // wrong on purpose: a write must work them out again.
    private static PdfDocument Sample() => StructureFixtures.File("/Outlines 20 0 R /Names <</Dests <</Names [(target) [4 0 R /Fit]]>>>>", pdf =>
    {
        pdf.Obj(20, "<</Type /Outlines /First 21 0 R /Last 23 0 R /Count 99>>");
        pdf.Obj(21, "<</Title (Chapter 1) /Parent 20 0 R /Next 22 0 R /First 24 0 R /Last 25 0 R /Count 7 /Dest [3 0 R /XYZ 0 300 null] /C [1 0 0] /F 3 /Unknown (kept)>>");
        pdf.Obj(22, "<</Title (Chapter 2) /Parent 20 0 R /Prev 21 0 R /Next 23 0 R /First 26 0 R /Last 26 0 R /Count -1 /Dest (target) /SE 21 0 R>>");
        pdf.Obj(23, "<</Title (Chapter 3) /Parent 20 0 R /Prev 22 0 R /Dest [5 0 R /Fit]>>");
        pdf.Obj(24, "<</Title (Section 1.1) /Parent 21 0 R /Next 25 0 R /A <</S /URI /URI (http://example.com)>>>>");
        pdf.Obj(25, "<</Title <FEFF04160410> /Parent 21 0 R /Prev 24 0 R /A <</S /GoTo /D [5 0 R /FitH 10]>>>>");
        pdf.Obj(26, "<</Title (Appendix \\(a\\)) /Parent 22 0 R>>");
    });

    private static PdfDocument Saved(PdfDocument document) => StructureFixtures.Reopen(document);

    [Fact]
    public void ReadsTheTree()
    {
        var outline = Outline.Read(Sample());
        Assert.Equal(["Chapter 1", "Chapter 2", "Chapter 3"], outline.Items.Select(i => i.Title));
        var one = outline.Items[0];
        Assert.True(one.IsOpen);
        Assert.False(outline.Items[1].IsOpen);
        Assert.Equal((1d, 0d, 0d), one.Color);
        Assert.True(one.Bold);
        Assert.True(one.Italic);
        Assert.Equal(new PdfDestination(0, DestinationFit.Xyz, 0, Top: 300), one.Destination);
        Assert.Equal(["Section 1.1", "ЖА"], one.Children.Select(c => c.Title));
        Assert.Equal("http://example.com", Assert.IsType<UriAction>(one.Children[0].Action).Uri);
        Assert.Null(one.Children[0].Destination);
        Assert.Equal(2, one.Children[1].Destination!.PageIndex);
        Assert.Equal("Appendix (a)", outline.Items[1].Children.Single().Title);
        Assert.Equal(1, outline.Items[1].Destination!.PageIndex);
        Assert.Equal("target", outline.Items[1].Destination!.Name);
        Assert.Same(one, one.Children[0].Parent);
    }

    [Fact]
    public void NoOutlinesIsEmpty()
    {
        Assert.Empty(Outline.Read(StructureFixtures.Open()).Items);
    }

    [Fact]
    public void WriteFixesCountsAndKeepsUnknownKeys()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        outline.Write(document);
        var reopened = Saved(document);

        var root = reopened.Dict(reopened.Catalog, "Outlines")!;
        Assert.Equal(5, reopened.Integer(root, "Count"));
        var first = reopened.Dict(root, "First")!;
        Assert.Equal(2, reopened.Integer(first, "Count"));
        Assert.Equal("kept", PdfText.Read(reopened, first, "Unknown"));
        var second = reopened.Dict(first, "Next")!;
        Assert.Equal(-1, reopened.Integer(second, "Count"));
        Assert.NotNull(second["SE"]);
        Assert.Null(reopened.Dict(second, "Next")!["Count"]);

        var again = Outline.Read(reopened);
        Assert.Equal(outline.Items.Select(i => i.Title), again.Items.Select(i => i.Title));
        Assert.Equal(outline.Items[1].Destination, again.Items[1].Destination);
    }

    [Fact]
    public void UntouchedActionsAndDestinationsAreNotRewritten()
    {
        var document = Sample();
        var before = document.Dict(document.Dict(document.Catalog, "Outlines"), "First")!;
        var item25 = document.Dict(document.Dict(before, "First"), "Next")!;
        string action = item25["A"]!.ToString();
        var outline = Outline.Read(document);
        outline.Items[0].Children[1].Title = "Renamed";
        outline.Write(document);
        Assert.Equal(action, item25["A"]!.ToString());
        Assert.Null(item25["Dest"]);
    }

    [Fact]
    public void PdfPigReadsTheBookmarks()
    {
        var document = Sample();
        Outline.Read(document).Write(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        Assert.True(pig.TryGetBookmarks(out var bookmarks));
        Assert.Equal(3, bookmarks.Roots.Count);
        Assert.Equal("Chapter 1", bookmarks.Roots[0].Title);
        Assert.Equal(2, bookmarks.Roots[0].Children.Count);
    }

    [Fact]
    public void BuildFromNothing()
    {
        var document = StructureFixtures.Open();
        var outline = Outline.Read(document);
        var a = outline.Add(new OutlineItem { Title = "Intro", Destination = StructureFixtures.ToPage(0), IsOpen = true });
        var b = outline.Add(new OutlineItem { Title = "Türkçe ğ", Destination = StructureFixtures.ToPage(1), Bold = true, Color = (0, 0, 1) });
        outline.Add(new OutlineItem { Title = "Detail", Destination = StructureFixtures.ToPage(2) }, a);
        outline.Add(new OutlineItem { Title = "Link", Action = new UriAction("http://x") }, a);
        outline.Write(document);

        var reopened = Saved(document);
        var read = Outline.Read(reopened);
        Assert.Equal(["Intro", "Türkçe ğ"], read.Items.Select(i => i.Title));
        Assert.Equal(["Detail", "Link"], read.Items[0].Children.Select(c => c.Title));
        Assert.Equal(1, read.Items[1].Destination!.PageIndex);
        Assert.True(read.Items[1].Bold);
        Assert.Equal((0d, 0d, 1d), read.Items[1].Color);
        Assert.Equal(4, reopened.Integer(reopened.Dict(reopened.Catalog, "Outlines"), "Count"));
        Assert.Equal("http://x", Assert.IsType<UriAction>(read.Items[0].Children[1].Action).Uri);
        Assert.NotNull(b.Reference);
    }

    [Fact]
    public void ClosedItemKeepsNegativeCount()
    {
        var document = StructureFixtures.Open();
        var outline = Outline.Read(document);
        var parent = outline.Add(new OutlineItem { Title = "p", Destination = StructureFixtures.ToPage(0) });
        outline.Add(new OutlineItem { Title = "c1", Destination = StructureFixtures.ToPage(0) }, parent);
        outline.Add(new OutlineItem { Title = "c2", Destination = StructureFixtures.ToPage(0) }, parent);
        outline.Write(document);
        Assert.Equal(-2, document.Integer(parent.Source, "Count"));
        Assert.Equal(1, document.Integer(document.Dict(document.Catalog, "Outlines"), "Count"));

        parent.IsOpen = true;
        outline.Write(document);
        Assert.Equal(2, document.Integer(parent.Source, "Count"));
        Assert.Equal(3, document.Integer(document.Dict(document.Catalog, "Outlines"), "Count"));
    }

    [Fact]
    public void RemoveFreesTheSubtree()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        var gone = outline.Items[0];
        outline.Remove(gone);
        outline.Write(document);
        Assert.Null(document.Get(21));
        Assert.Null(document.Get(24));
        Assert.Null(document.Get(25));
        Assert.NotNull(document.Get(22));

        var reopened = Saved(document);
        var read = Outline.Read(reopened);
        Assert.Equal(["Chapter 2", "Chapter 3"], read.Items.Select(i => i.Title));
        Assert.Equal(2, reopened.Integer(reopened.Dict(reopened.Catalog, "Outlines"), "Count"));
    }

    [Fact]
    public void RemovingEverythingTakesOutlinesAway()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        foreach (var item in outline.Items.ToList()) outline.Remove(item);
        outline.Write(document);
        Assert.Null(document.Catalog["Outlines"]);
        Assert.Null(document.Get(20));
        Assert.Empty(Outline.Read(Saved(document)).Items);
    }

    [Fact]
    public void RenameAndMove()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        var chapter3 = outline.Items[2];
        chapter3.Title = "Last chapter";
        outline.Move(chapter3, outline.Items[0], 0);
        outline.Move(outline.Items[1], null, 0);
        outline.Write(document);

        var read = Outline.Read(Saved(document));
        Assert.Equal(["Chapter 2", "Chapter 1"], read.Items.Select(i => i.Title));
        Assert.Equal(["Last chapter", "Section 1.1", "ЖА"], read.Items[1].Children.Select(c => c.Title));
        Assert.Equal(3, read.Items[1].Children.Count);
    }

    [Fact]
    public void MoveWithinTheSameParentTakesTheIndexAfterTheRemoval()
    {
        var outline = Outline.Read(Sample());
        var first = outline.Items[0];
        outline.Move(first, null, 3);
        Assert.Equal(["Chapter 2", "Chapter 3", "Chapter 1"], outline.Items.Select(i => i.Title));
        outline.Move(first, null, 0);
        Assert.Equal("Chapter 1", outline.Items[0].Title);
    }

    [Fact]
    public void ItemCannotMoveIntoItself()
    {
        var outline = Outline.Read(Sample());
        var one = outline.Items[0];
        Assert.Throws<ArgumentException>(() => outline.Move(one, one));
        Assert.Throws<ArgumentException>(() => outline.Move(one, one.Children[0]));
        Assert.Throws<ArgumentException>(() => outline.Add(one.Children[0], one));
        Assert.Throws<ArgumentException>(() => outline.Move(new OutlineItem(), null));
    }

    [Fact]
    public void ChangedDestinationReplacesTheAction()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        var link = outline.Items[0].Children[0];
        link.Destination = StructureFixtures.ToPage(2);
        outline.Write(document);
        Assert.Null(link.Source!["A"]);
        Assert.Equal(2, PdfDestinations.Parse(document, link.Source["Dest"])!.PageIndex);

        var goTo = outline.Items[0].Children[1];
        goTo.Destination = null;
        outline.Write(document);
        Assert.Null(goTo.Source!["A"]);
        Assert.Null(goTo.Source["Dest"]);
        Assert.Null(goTo.Action);
    }

    [Fact]
    public void ChangedActionReplacesTheDestination()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        var item = outline.Items[0];
        item.Action = new NamedAction("NextPage");
        outline.Write(document);
        Assert.Null(item.Source!["Dest"]);
        Assert.Equal("NextPage", PdfActions.Read(document, item.Source["A"]) is NamedAction n ? n.Name : null);
    }

    [Fact]
    public void ItemWithAPageThatIsGoneKeepsItsDestination()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R", pdf =>
        {
            pdf.Obj(20, "<</Type /Outlines /First 21 0 R /Last 21 0 R /Count 1>>");
            pdf.Obj(21, "<</Title (Old) /Parent 20 0 R /Dest [77 0 R /Fit]>>");
        });
        var outline = Outline.Read(document);
        Assert.Equal(-1, outline.Items[0].Destination!.PageIndex);
        outline.Items[0].Title = "Still old";
        outline.Write(document);
        Assert.Equal("[77 0 R /Fit]", outline.Items[0].Source!["Dest"]!.ToString());
    }

    [Fact]
    public void LoopsInTheChainsAreCut()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R", pdf =>
        {
            pdf.Obj(20, "<</Type /Outlines /First 21 0 R>>");
            pdf.Obj(21, "<</Title (a) /Parent 20 0 R /Next 22 0 R /First 20 0 R>>");
            pdf.Obj(22, "<</Title (b) /Parent 20 0 R /Next 21 0 R /First 22 0 R>>");
        });
        var outline = Outline.Read(document);
        Assert.Equal(["a", "b"], outline.Items.Select(i => i.Title));
        Assert.All(outline.Items, i => Assert.Empty(i.Children));
        outline.Write(document);
        Assert.Equal(2, Outline.Read(StructureFixtures.Reopen(document)).Items.Count);
    }

    [Fact]
    public void BrokenChainsAreCutAtTheBreak()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R", pdf =>
        {
            pdf.Obj(20, "<</Type /Outlines /First 21 0 R>>");
            pdf.Obj(21, "<</Title (a) /Next 99 0 R /First 23 0 R>>");
            pdf.Obj(23, "<</Title (kid) /Next 24 0 R>>");
            pdf.Obj(24, "(not a dictionary)");
        });
        var outline = Outline.Read(document);
        Assert.Single(outline.Items);
        Assert.Equal(["kid"], outline.Items[0].Children.Select(c => c.Title));
    }

    [Fact]
    public void TitlelessItemsAreEmptyTitles()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R", pdf =>
        {
            pdf.Obj(20, "<</First 21 0 R>>");
            pdf.Obj(21, "<</Dest [3 0 R /Fit]>>");
        });
        Assert.Equal("", Outline.Read(document).Items.Single().Title);
    }

    [Fact]
    public void DeepNestingIsCutAtSixtyFourLevels()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R", pdf =>
        {
            pdf.Obj(20, "<</First 21 0 R>>");
            for (int i = 0; i < 200; i++) pdf.Obj(21 + i, $"<</Title (L{i}) /First {22 + i} 0 R>>");
        });
        int depth = 0;
        for (var item = Outline.Read(document).Items.SingleOrDefault(); item is not null; item = item.Children.SingleOrDefault()) depth++;
        Assert.Equal(64, depth);
    }

    [Fact]
    public void LargeOutlineWritesAndReads()
    {
        var document = StructureFixtures.Open();
        var outline = Outline.Read(document);
        for (int i = 0; i < 3000; i++) outline.Add(new OutlineItem { Title = $"Item {i}", Destination = StructureFixtures.ToPage(i % 3) });
        outline.Write(document);
        var read = Outline.Read(Saved(document));
        Assert.Equal(3000, read.Items.Count);
        Assert.Equal("Item 2999", read.Items[^1].Title);
        Assert.Equal(2, read.Items[2999].Destination!.PageIndex);
    }

    [Fact]
    public void LinksOfOutlineMatchPdfPigAfterEdit()
    {
        var document = Sample();
        var outline = Outline.Read(document);
        outline.Move(outline.Items[2], outline.Items[0]);
        outline.Write(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        Assert.True(pig.TryGetBookmarks(out var bookmarks));
        Assert.Equal(2, bookmarks.Roots.Count);
        Assert.Equal(3, bookmarks.Roots[0].Children.Count);
    }
}
