using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class CommentListTests
{
    private static readonly DateTimeOffset Day = new(2026, 3, 1, 9, 0, 0, TimeSpan.Zero);

    private static (PdfDocument Document, PdfAnnotation Low, PdfAnnotation High, PdfAnnotation OnSecond) Sample()
    {
        var document = Blank(2);
        var writer = new PdfAnnotationWriter(document);
        var low = writer.AddNote(document.Pages[0], new PdfRect(50, 100, 70, 120), new AnnotationInfo("Zeynep", "low on page one", null, Day.AddHours(2)));
        var high = writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(50, 700, 150, 714))],
            new AnnotationInfo("ali", "high on page one", null, Day.AddHours(1)));
        var onSecond = writer.AddSquare(document.Pages[1], new PdfRect(10, 10, 80, 80), null, new AnnotationInfo("Ali", "box", null, Day));
        return (document, low, high, onSecond);
    }

    [Fact]
    public void PageOrderReadsTopToBottom()
    {
        var (document, _, _, _) = Sample();
        var list = PdfComments.List(document);
        Assert.Equal(["high on page one", "low on page one", "box"], list.Select(c => c.Text));
        Assert.Equal([0, 0, 1], list.Select(c => c.PageIndex));
        Assert.Equal(["Highlight", "Note", "Rectangle"], list.Select(c => AnnotationText.KindName(c.Type)));
    }

    [Fact]
    public void SortsByDateAuthorAndType()
    {
        var (document, _, _, _) = Sample();
        Assert.Equal(["box", "high on page one", "low on page one"], PdfComments.List(document, null, CommentOrder.Date).Select(c => c.Text));
        Assert.Equal(["low on page one", "high on page one", "box"], PdfComments.List(document, null, CommentOrder.Date, descending: true).Select(c => c.Text));
        Assert.Equal(["Zeynep"], PdfComments.List(document, null, CommentOrder.Author, descending: true).Select(c => c.Author).Take(1));
        Assert.Equal(["ali", "Ali", "Zeynep"], PdfComments.List(document, null, CommentOrder.Author).Select(c => c.Author));
        Assert.Equal(["Highlight", "Note", "Rectangle"], PdfComments.List(document, null, CommentOrder.Type).Select(c => AnnotationText.KindName(c.Type)));
    }

    [Fact]
    public void FiltersByAuthorTextPageAndType()
    {
        var (document, _, _, _) = Sample();
        Assert.Equal(2, PdfComments.List(document, new CommentFilter(Author: "ALI")).Count);
        Assert.Equal(["low on page one"], PdfComments.List(document, new CommentFilter(Text: "LOW")).Select(c => c.Text));
        Assert.Equal(["box"], PdfComments.List(document, new CommentFilter(PageIndex: 1)).Select(c => c.Text));
        Assert.Equal(["high on page one"], PdfComments.List(document, new CommentFilter(Types: [AnnotationType.Highlight])).Select(c => c.Text));
        Assert.Empty(PdfComments.List(document, new CommentFilter(Text: "nothing like this")));
    }

    [Fact]
    public void LinksWidgetsAndPopupsAreNotComments()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Subtype /Link /Rect [0 0 5 5]>>");
            pdf.Obj(21, "<</Subtype /Widget /Rect [0 0 5 5]>>");
            pdf.Obj(22, "<</Subtype /Popup /Rect [0 0 5 5]>>");
            pdf.Obj(23, "<</Subtype /Text /Rect [0 0 5 5] /Contents (yes)>>");
        }, "/Annots [20 0 R 21 0 R 22 0 R 23 0 R]");
        Assert.Equal("yes", Assert.Single(PdfComments.List(document)).Text);
    }

    [Fact]
    public void RepliesJoinTheirThreadWhateverTheDepth()
    {
        var (document, low, _, _) = Sample();
        var first = PdfComments.Reply(document, low, "agreed", "Can", Day.AddHours(3));
        var second = PdfComments.Reply(document, first, "me too", "Deniz", Day.AddHours(4));
        Assert.Equal(low.Reference, first.InReplyTo);
        Assert.Equal("R", first.ReplyType);
        Assert.True(first.Flags.HasFlag(AnnotationFlags.Hidden));
        Assert.Equal(first.Reference, second.InReplyTo);

        var list = PdfComments.List(document);
        Assert.Equal(3, list.Count);
        var thread = list.Single(c => c.Text == "low on page one");
        Assert.Equal(["agreed", "me too"], thread.Replies.Select(r => r.Contents));
        Assert.Equal(["Can", "Deniz"], thread.Replies.Select(r => r.Title));
        Assert.Single(PdfComments.List(document, new CommentFilter(HasReplies: true)));
        Assert.Single(PdfComments.List(document, new CommentFilter(Author: "deniz")));
        Reopen(document);
    }

    [Fact]
    public void StatusFollowsTheLatestChange()
    {
        var (document, low, high, _) = Sample();
        Assert.All(PdfComments.List(document), c => Assert.Equal(ReviewStatus.None, c.Status));
        PdfComments.SetStatus(document, low, ReviewStatus.Accepted, "Can", Day.AddHours(5));
        var rejected = PdfComments.SetStatus(document, low, ReviewStatus.Rejected, "Deniz", Day.AddHours(6));
        PdfComments.SetStatus(document, high, ReviewStatus.Marked, "Can", Day);

        Assert.Equal("Review", PdfText.Read(document, rejected.Dictionary, "StateModel"));
        Assert.Equal("Rejected", PdfText.Read(document, rejected.Dictionary, "State"));
        Assert.Equal(ReviewStatus.Rejected, PdfComments.List(document).Single(c => c.Text == "low on page one").Status);
        Assert.Equal(ReviewStatus.Marked, PdfComments.List(document).Single(c => c.Text == "high on page one").Status);
        Assert.Equal(["low on page one"], PdfComments.List(document, new CommentFilter(Status: ReviewStatus.Rejected)).Select(c => c.Text));
        Assert.Equal("Rejected set by Deniz", rejected.Contents);

        var reopened = Reopen(document);
        Assert.Equal(ReviewStatus.Rejected, PdfComments.List(reopened).Single(c => c.Text == "low on page one").Status);
    }

    [Fact]
    public void MarkedModelUsesItsOwnName()
    {
        var (document, low, _, _) = Sample();
        var marked = PdfComments.SetStatus(document, low, ReviewStatus.Unmarked, "Can", Day);
        Assert.Equal("Marked", PdfText.Read(document, marked.Dictionary, "StateModel"));
        Assert.Equal(ReviewStatus.Unmarked, marked.State);
    }

    [Fact]
    public void ReplyNeedsAnIndirectAnnotationOnAPage()
    {
        var document = Blank(1, pageEntries: "/Annots [<</Subtype /Text /Rect [0 0 5 5]>>]");
        var direct = PdfAnnotations.Read(document, document.Pages[0]).Single();
        Assert.Throws<ArgumentException>(() => PdfComments.Reply(document, direct, "x", "A", Day));
    }

    [Fact]
    public void DanglingReplyCountsAsAComment()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Subtype /Text /Rect [0 0 5 5] /IRT 99 0 R /Contents (orphan)>>"), "/Annots [20 0 R]");
        Assert.Equal("orphan", Assert.Single(PdfComments.List(document)).Text);
    }

    [Fact]
    public void RichTextOnlyCommentShowsPlainText()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Subtype /FreeText /Rect [0 0 50 50] /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one</p><p>two</p></body>)>>"), "/Annots [20 0 R]");
        Assert.Equal("one\ntwo", PdfComments.List(document).Single().Text);
    }
}
