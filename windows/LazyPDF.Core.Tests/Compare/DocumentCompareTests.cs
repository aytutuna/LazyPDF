using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class DocumentCompareTests
{
    private static readonly string[][] Text = [Page("doc"), Page("two")];

    private static PdfDocument Edited(Action<PdfDocument> edit)
    {
        using var document = Doc(Text);
        edit(document);
        return Open(document.SaveRewrite());
    }

    private static ComparisonResult Run(Action<PdfDocument> before, Action<PdfDocument> after)
    {
        using var a = Edited(before);
        using var b = Edited(after);
        return PdfComparer.Compare(a, b);
    }

    private static void Nothing(PdfDocument d) { }

    private static IReadOnlyList<CompareChange> Document(ComparisonResult r) => [.. r.Changes.Where(c => c.Area == ChangeArea.Document)];

    private static void Title(PdfDocument d, string title) => (DocumentMetadata.Read(d) with { Title = title }).Write(d);

    [Fact]
    public void TitleAuthorAndCustomKeysAreCompared()
    {
        var result = Run(d => (DocumentMetadata.Read(d) with { Title = "Old", Author = "Ann" }).Write(d),
            d => (DocumentMetadata.Read(d) with { Title = "New", Subject = "S", Custom = new Dictionary<string, string> { ["Project"] = "X" } }).Write(d));
        var changes = Document(result).ToDictionary(c => c.Detail!);
        Assert.Equal((ChangeKind.Changed, "Old", "New"), (changes["Title"].Kind, changes["Title"].OldText, changes["Title"].NewText));
        Assert.Equal(ChangeKind.Removed, changes["Author"].Kind);
        Assert.Equal(ChangeKind.Added, changes["Subject"].Kind);
        Assert.Equal("X", changes["Project"].NewText);
        Assert.All(changes.Values, c => Assert.Empty(c.OldQuads.Concat(c.NewQuads)));
        Assert.Equal(4, result.Summary.Document);
    }

    [Fact]
    public void SameMetadataIsNoChange() => Assert.True(Run(d => Title(d, "T"), d => Title(d, "T")).IsIdentical);

    [Fact]
    public void PageSizeChangeIsAPageChange()
    {
        using var a = Doc(Text);
        string file = TestPdf.Text(Bytes([.. Text.Select(p => p.Select(L).ToArray())])).Replace("/MediaBox [0 0 612 792]", "/MediaBox [0 0 595 842]");
        using var b = Open(TestPdf.Latin(file));
        var result = PdfComparer.Compare(a, b);
        Assert.Equal(2, result.Changes.Count(c => c.Area == ChangeArea.Page && c.Kind == ChangeKind.Changed));
        var change = result.Changes[0];
        Assert.Contains("612 x 792", change.Detail);
        Assert.Contains("595 x 842", change.Detail);
    }

    private static void Bookmarks(PdfDocument d, params (string Title, int Page, int Level)[] items)
    {
        var outline = Outline.Read(d);
        OutlineItem? parent = null;
        foreach (var (title, page, level) in items)
        {
            var item = new OutlineItem { Title = title, Destination = new PdfDestination(page) };
            if (level == 0) parent = outline.Add(item);
            else outline.Add(item, parent);
        }
        outline.Write(d);
    }

    [Fact]
    public void BookmarksAddedRemovedAndRetitled()
    {
        var result = Run(d => Bookmarks(d, ("Intro", 0, 0), ("Body", 1, 0), ("Old end", 1, 0)),
            d => Bookmarks(d, ("Intro", 0, 0), ("Body part", 1, 0), ("Appendix", 1, 0), ("Index", 1, 0)));
        var changes = Document(result);
        Assert.All(changes, c => Assert.Equal(CompareText.Bookmark, c.Detail));
        var change = Assert.Single(changes);
        Assert.Equal((ChangeKind.Changed, "Body; Old end", "Body part; Appendix; Index"), (change.Kind, change.OldText, change.NewText));
    }

    [Fact]
    public void BookmarkThatPointsAtAnotherPage()
    {
        var change = Assert.Single(Document(Run(d => Bookmarks(d, ("Part", 0, 0)), d => Bookmarks(d, ("Part", 1, 0)))));
        Assert.Equal(CompareText.BookmarkPage, change.Detail);
    }

    [Fact]
    public void BookmarkFollowsAPageThatMoved()
    {
        // Both bookmarks go to the page that holds the same text; the page moved, the bookmark did not change its meaning.
        using var a = Doc(Text);
        Bookmarks(a, ("Two", 1, 0));
        using var before = Open(a.SaveRewrite());
        using var b = Doc([Text[1], Text[0]]);
        Bookmarks(b, ("Two", 0, 0));
        using var after = Open(b.SaveRewrite());
        var result = PdfComparer.Compare(before, after);
        Assert.Empty(Document(result));
    }

    [Fact]
    public void AttachmentsAreComparedByContent()
    {
        var result = Run(d =>
        {
            PdfAttachments.Add(d, "a.txt", "one"u8.ToArray(), "text/plain", null, null, null);
            PdfAttachments.Add(d, "gone.txt", "x"u8.ToArray(), "text/plain", null, null, null);
        }, d =>
        {
            PdfAttachments.Add(d, "a.txt", "two"u8.ToArray(), "text/plain", null, null, null);
            PdfAttachments.Add(d, "new.txt", "y"u8.ToArray(), "text/plain", null, null, null);
        });
        var changes = Document(result).ToDictionary(c => c.Detail!);
        Assert.Equal(ChangeKind.Changed, changes["Attachment a.txt"].Kind);
        Assert.Equal(ChangeKind.Removed, changes["Attachment gone.txt"].Kind);
        Assert.Equal(ChangeKind.Added, changes["Attachment new.txt"].Kind);
    }

    [Fact]
    public void SameAttachmentIsNoChange()
    {
        void Add(PdfDocument d) => PdfAttachments.Add(d, "a.txt", "one"u8.ToArray(), "text/plain", null, null, null);
        Assert.True(Run(Add, Add).IsIdentical);
    }

    private static void FormField(PdfDocument d, string name, string? value)
    {
        var form = PdfForm.Read(d);
        form.AddField(new FieldSpec(FieldKind.Text, name, 0, new PdfRect(100, 400, 300, 420)) { Value = value });
    }

    [Fact]
    public void FormValuesAreCompared()
    {
        var result = Run(d =>
        {
            FormField(d, "name", "Ann");
            FormField(d, "city", "Rome");
        }, d =>
        {
            FormField(d, "name", "Bob");
            FormField(d, "zip", "123");
        });
        var changes = Document(result).ToDictionary(c => c.Detail!);
        Assert.Equal(("Ann", "Bob"), (changes["Form field name"].OldText, changes["Form field name"].NewText));
        Assert.Equal(ChangeKind.Removed, changes["Form field city"].Kind);
        Assert.Equal(ChangeKind.Added, changes["Form field zip"].Kind);
    }

    [Fact]
    public void SameFormValuesAreNoChange()
    {
        void Fill(PdfDocument d) => FormField(d, "name", "Ann");
        Assert.True(Run(Fill, Fill).IsIdentical);
    }
}
