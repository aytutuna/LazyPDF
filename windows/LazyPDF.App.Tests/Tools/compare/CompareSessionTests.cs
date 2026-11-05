using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The comparison behind the panel: Core's differences as rows, the filters, the pixel mode and the report.
public sealed class CompareSessionTests
{
    [Fact]
    public void EveryKindOfDifferenceBecomesARow()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        var rows = session.Rows(Parts.All);

        Assert.Equal(session.Result!.Changes.Count, rows.Count);
        Assert.Contains(rows, r => r.Title == "other" && r.Kind == ChangeKind.Added);
        Assert.Contains(rows, r => r.Title.Contains("name"));
        Assert.All(rows, r => Assert.False(string.IsNullOrEmpty(r.Spoken)));
    }

    [Fact]
    public void ATextRowKnowsItsPageAndWhereOnThePageItIs()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        var row = session.Rows(Parts.Text).First(r => r.Title == "other");

        Assert.Equal(0, row.NewPage);
        Assert.Equal("Added · Page 1", row.Subtitle);
        var area = row.NewArea!.Value;
        var page = session.New.Document.Pages[0];
        Assert.InRange(area.Left, 0, new PageGeometry(page).Width);
        Assert.InRange(area.Top, 0, new PageGeometry(page).Height);
        Assert.True(area.Height > 0);
    }

    [Fact]
    public void TheFiltersKeepOnlyWhatIsSwitchedOn()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        Assert.All(session.Rows(Parts.Forms), r => Assert.Contains("name", r.Title));
        Assert.Single(session.Rows(Parts.Forms));
        Assert.Contains(session.Rows(Parts.Details), r => r.Title.Contains("Title"));
        Assert.Empty(session.Rows(Parts.Pictures | Parts.Annotations));
        Assert.Equal(session.Rows(Parts.All).Count, session.Rows(Parts.Text).Count + session.Rows(Parts.Forms).Count + session.Rows(Parts.Details).Count);
    }

    [Fact]
    public void TheSameFileTwiceHasNothingToShow()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.Before());

        Assert.True(session.Result!.IsIdentical);
        Assert.Empty(session.Rows(Parts.All));
        Assert.Equal("No differences found.", CompareFlow.Headline(session, 0));
    }

    [Fact]
    public void ThePanelHeadlineCountsWhatIsShown()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        Assert.Equal($"{session.Rows(Parts.All).Count} differences", CompareFlow.Headline(session, session.Rows(Parts.All).Count));
        Assert.Equal("Nothing to show with these filters.", CompareFlow.Headline(session, 0));
        Assert.StartsWith("Words: ", CompareFlow.Note(session));
    }

    [Fact]
    public void PixelModeFindsTheBlockOnEachPage()
    {
        var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Painted());
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: true, CancellationToken.None);

            var rows = session.Rows(Parts.Text);

            Assert.True(session.ByPixels);
            Assert.Equal([0, 1], rows.Select(r => r.NewPage).Distinct().Order());
            Assert.All(rows, r => Assert.Null(r.Kind));
            var area = rows[0].NewArea!.Value;
            Assert.True(area.Contains(67.5, 90), "the region covers the block (96 dpi pixels are 0.75 pt)");
            Assert.Equal("2 areas differ", CompareFlow.Headline(session, 2));
        }
    }

    [Fact]
    public void ThePictureOfAPageShowsWhereItChanged()
    {
        var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Painted());
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: false, CancellationToken.None);

            var overlay = session.Overlay(0)!;

            Assert.Equal((200, 300), (overlay.Width, overlay.Height));
            int at = (120 * 200 + 90) * 4;
            Assert.True(overlay.Rgba[at + 1] > overlay.Rgba[at], "ink only the new page has is green");
            Assert.Null(session.Overlay(5));
        }
    }

    [Fact]
    public void ThePictureOfAnAddedPageIsNotMade()
    {
        using var session = CompareKit.Session(Pdfs.Text(1, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."), Pdfs.Text(2, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."));

        int added = session.Result!.Pages.First(p => p.IsAdded).NewIndex;

        Assert.Null(session.Overlay(added));
    }

    [Fact]
    public void TheReportIsAFileThatOpensAgainWithTheSummaryInFront()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        var report = session.Report(Parts.All, new FakeFonts());

        using var again = PdfDocument.Open(report);
        Assert.True(again.Pages.Count > session.New.PageCount);
        string text = ComparisonReport.ToText(session.Result!, "old.pdf", "new.pdf");
        Assert.Contains("other", text);
    }

    [Fact]
    public void AReportOfOneKindLeavesTheOthersOut()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        var only = ChangeParts.Only(session.Result!, Parts.Forms);

        Assert.Single(only.Changes);
        Assert.Equal(1, only.Summary.Total);
        Assert.Equal(1, only.Summary.Document);
        Assert.Equal(0, only.Summary.Text);
        Assert.Same(session.Result, ChangeParts.Only(session.Result!, Parts.All));
    }

    [Fact]
    public void APixelComparisonListsAddedAndRemovedPages()
    {
        var session = new CompareSession(new Side(Pdfs.Text(3, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."), "old.pdf", null, null),
            new Side(Pdfs.Text(2, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."), "new.pdf", null, null), CompareKit.Painted());
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: true, CancellationToken.None);

            var rows = session.Rows(Parts.All);

            Assert.Contains(rows, r => r.Kind == ChangeKind.Removed && r.NewPage < 0);
            Assert.Equal("Page removed", rows.First(r => r.Kind == ChangeKind.Removed).Title);
            Assert.NotEqual("No differences found.", CompareFlow.Headline(session, rows.Count));
        }
    }

    [Fact]
    public void PagesThatCannotBeDrawnAreNotCalledTheSame()
    {
        var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), () => new FakeRenderer { Draws = false });
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: true, CancellationToken.None);

            Assert.Empty(session.Rows(Parts.All));
            Assert.Equal("Pages could not be drawn.", CompareFlow.Headline(session, 0));
            Assert.Equal("2 pages could not be drawn.", CompareFlow.Note(session));
        }
    }

    [Fact]
    public void ANoisyPageDoesNotUseUpTheList()
    {
        var session = new CompareSession(new Side(CompareKit.Before(), "old.pdf", null, null), new Side(CompareKit.Before(), "new.pdf", null, null), CompareKit.Speckled());
        using (session)
        {
            session.Compare(new CompareOptions(), byPixels: true, CancellationToken.None);

            var rows = session.Rows(Parts.All);

            Assert.Equal([0, 1], rows.Select(r => r.NewPage).Distinct().Order());
            Assert.Equal(50, rows.Count(r => r.NewPage == 0));
            Assert.Null(CompareFlow.Note(session));
        }
    }
}
