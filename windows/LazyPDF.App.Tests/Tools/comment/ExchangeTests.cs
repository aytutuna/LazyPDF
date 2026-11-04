using System.Windows;
using LazyPDF.App.Panels.Comments;
using LazyPDF.App.Tools.Comment;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

// Comments out to FDF and XFDF and back in, flattening, and the plain text summary.
public sealed class ExchangeTests
{
    private static readonly MarkStyle Red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1] };

    private static CommentFixture WithMarks()
    {
        var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], Red);
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(300, 100)], Red, "Check the total");
        PdfComments.Reply(f.Document, note, "Done", "Can", new DateTimeOffset(2026, 11, 5, 9, 0, 0, TimeSpan.Zero));
        f.Tab.Commit("Marks");
        return f;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ExportedCommentsComeBackIntoAnotherCopy(bool xfdf)
    {
        using var source = WithMarks();
        using var target = new CommentFixture();

        byte[] data = Exchange.Export(source.Document, "a.pdf", xfdf).Data;
        var result = Exchange.Import(target.Document, data, xfdf, new FakeFonts());

        Assert.True(result.Imported >= 2);
        Assert.Equal(0, result.Skipped);
        target.Tab.Commit("Import comments");
        var comments = PdfComments.List(target.Document);
        Assert.Equal(2, comments.Count);
        Assert.Contains(comments, c => c.Text == "Check the total" && c.Replies.Count == 1);
    }

    [Fact]
    public void ImportingTheSameFileTwiceAddsNothingTheSecondTime()
    {
        using var source = WithMarks();
        using var target = new CommentFixture();
        byte[] data = Exchange.Export(source.Document, null, xfdf: false).Data;
        Exchange.Import(target.Document, data, xfdf: false, new FakeFonts());
        target.Tab.Commit("Import comments");

        var again = Exchange.Import(target.Document, data, xfdf: false, new FakeFonts());

        Assert.Equal(0, again.Imported);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AFileThatIsNotACommentFileIsRefused(bool xfdf)
    {
        using var f = new CommentFixture();

        Assert.Throws<PdfReadException>(() => Exchange.Import(f.Document, [1, 2, 3, 4], xfdf, new FakeFonts()));
    }

    [Theory]
    [InlineData("notes.xfdf", true)]
    [InlineData("NOTES.XFDF", true)]
    [InlineData("notes.fdf", false)]
    [InlineData("notes", false)]
    public void TheExtensionSaysWhichFormat(string path, bool xfdf) => Assert.Equal(xfdf, Exchange.IsXfdf(path));

    [Fact]
    public void FlatteningBurnsTheMarksIntoThePagesAndOneUndoBringsThemBack()
    {
        using var f = WithMarks();
        int before = Exchange.Flattenable(f.Document);

        int burned = Exchange.Flatten(f.Document, CancellationToken.None);
        f.Tab.Commit("Flatten comments");

        Assert.Equal(before, burned);
        Assert.True(burned >= 2);
        Assert.Empty(f.Marks());
        Assert.Equal(0, Exchange.Flattenable(f.Document));
        Assert.True(f.Tab.Undo());
        Assert.Equal(before, Exchange.Flattenable(f.Document));
    }

    [Fact]
    public void AFileWithNoMarksHasNothingToFlatten()
    {
        using var f = new CommentFixture();

        Assert.Equal(0, Exchange.Flattenable(f.Document));
        Assert.Equal(0, Exchange.Flatten(f.Document, CancellationToken.None));
    }

    [Fact]
    public void TheSummaryListsEachCommentWithItsRepliesAndStatus()
    {
        using var f = new CommentFixture();
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], Red, "Check the total");
        var date = new DateTimeOffset(2026, 11, 5, 9, 0, 0, TimeSpan.Zero);
        PdfComments.Reply(f.Document, note, "Done", "Can", date);
        PdfComments.SetStatus(f.Document, note, ReviewStatus.Accepted, "Can", date);
        f.Tab.Commit("Marks");

        string text = CommentSummary.Text("a.pdf", PdfComments.List(f.Document), page => (page + 1).ToString());

        string[] lines = text.ReplaceLineEndings("\n").Split('\n');
        Assert.Equal("a.pdf", lines[0]);
        Assert.Equal("1 comment", lines[1]);
        Assert.Equal("Page 1, Note, Ana, 2026-11-04", lines[3]);
        Assert.Equal("  Check the total", lines[4]);
        Assert.Equal("  Status: Accepted", lines[5]);
        Assert.Equal("  Reply from Can: Done", lines[6]);
        Assert.DoesNotContain("set by", text);
    }

    [Fact]
    public void ARowSaysItsStatusAndCountsOnlyRealReplies()
    {
        using var f = new CommentFixture();
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], Red, "Question");
        PdfComments.Reply(f.Document, note, "Answer", "Can", DateTimeOffset.Now);
        PdfComments.SetStatus(f.Document, note, ReviewStatus.Rejected, "Can", DateTimeOffset.Now.AddSeconds(1));
        f.Tab.Commit("Marks");

        var row = new CommentRow(PdfComments.List(f.Document).Single(), "Page 1", "Page 1");

        Assert.Equal("Note · Ana", row.Title);
        Assert.Equal("Page 1 · Rejected · 1 reply", row.Where);
        Assert.Equal("Note · Ana, Page 1 · Rejected · 1 reply, Question", row.Summary);
    }

    [Fact]
    public void FilteringAndGroupingUseTheListTheEngineGives()
    {
        using var f = new CommentFixture();
        var rect = f.Marker.Add(MarkTool.Rectangle, 0, [new Point(60, 80), new Point(260, 140)], Red);
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(300, 100)], Red, "Check the total");
        PdfComments.SetStatus(f.Document, note, ReviewStatus.Completed, "Can", DateTimeOffset.Now);
        f.Tab.Commit("Marks");

        var done = PdfComments.List(f.Document, new CommentFilter(Status: ReviewStatus.Completed));
        var byText = PdfComments.List(f.Document, new CommentFilter(Text: "total"));
        var byType = PdfComments.List(f.Document, order: CommentOrder.Type);

        Assert.Equal(AnnotationType.Text, Assert.Single(done).Type);
        Assert.Equal(AnnotationType.Text, Assert.Single(byText).Type);
        Assert.Equal(["Note", "Rectangle"], byType.Select(c => AnnotationText.KindName(c.Type)));
        Assert.NotNull(rect.Reference);
    }
}
