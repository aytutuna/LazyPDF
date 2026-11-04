using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class AnnotationCompareTests
{
    private static readonly string[][] Text = [Page("note")];

    /// <summary>The page with the annotations <paramref name="add"/> puts on it, saved and read again.</summary>
    private static PdfDocument WithNotes(Action<PdfAnnotationWriter, PdfPage> add)
    {
        using var document = Doc(Text);
        add(new PdfAnnotationWriter(document), document.Pages[0]);
        return Open(document.SaveRewrite());
    }

    private static readonly PdfRect Box = new(100, 500, 200, 520);

    private static ComparisonResult Run(Action<PdfAnnotationWriter, PdfPage> before, Action<PdfAnnotationWriter, PdfPage> after)
    {
        using var a = WithNotes(before);
        using var b = WithNotes(after);
        return PdfComparer.Compare(a, b);
    }

    private static void Nothing(PdfAnnotationWriter w, PdfPage p) { }

    private static void Square(PdfAnnotationWriter w, PdfPage p) => w.AddSquare(p, Box, new AnnotationStyle(), new AnnotationInfo("a", "first"));

    [Fact]
    public void SameAnnotationsAreNoChange() => Assert.True(Run(Square, Square).IsIdentical);

    [Fact]
    public void AddedAnnotation()
    {
        var change = Assert.Single(Run(Nothing, Square).Changes);
        Assert.Equal((ChangeKind.Added, ChangeArea.Annotation, "Square", "first"), (change.Kind, change.Area, change.Detail, change.NewText));
        Assert.Single(change.NewQuads);
    }

    [Fact]
    public void RemovedAnnotation()
    {
        var change = Assert.Single(Run(Square, Nothing).Changes);
        Assert.Equal((ChangeKind.Removed, "first"), (change.Kind, change.OldText));
        Assert.Single(change.OldQuads);
        Assert.Single(change.NewQuads);
    }

    [Fact]
    public void ChangedCommentTextIsFoundByAnotherCopyOfTheSameNote()
    {
        // Two separately written squares have different names, so this pairs by kind and place.
        var change = Assert.Single(Run(Square, (w, p) => w.AddSquare(p, Box, new AnnotationStyle(), new AnnotationInfo("a", "second"))).Changes);
        Assert.Equal(ChangeKind.Changed, change.Kind);
        Assert.Equal(("first", "second"), (change.OldText, change.NewText));
        Assert.Contains(CompareText.AnnotationText, change.Detail);
    }

    [Fact]
    public void EditedNoteIsPairedByName()
    {
        using var document = Doc(Text);
        var writer = new PdfAnnotationWriter(document);
        var note = writer.AddSquare(document.Pages[0], Box, new AnnotationStyle(), new AnnotationInfo("a", "first"));
        using var before = Open(document.SaveRewrite());
        writer.Move(note, 300, 100);
        writer.SetContents(note, "second");
        writer.SetColor(note, [0, 0, 1]);
        using var after = Open(document.SaveRewrite());
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Changed, change.Kind);
        Assert.Contains(CompareText.AnnotationText, change.Detail);
        Assert.Contains(CompareText.AnnotationPosition, change.Detail);
        Assert.Contains(CompareText.AnnotationColor, change.Detail);
        Assert.InRange(Assert.Single(change.NewQuads).Bounds.Left, 399, 401);
    }

    [Fact]
    public void MovedNoteIsOneChange()
    {
        using var document = Doc(Text);
        var writer = new PdfAnnotationWriter(document);
        var note = writer.AddCircle(document.Pages[0], Box);
        using var before = Open(document.SaveRewrite());
        writer.Move(note, 0, -200);
        using var after = Open(document.SaveRewrite());
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(CompareText.AnnotationPosition, change.Detail!.Split(": ")[1]);
    }

    [Fact]
    public void SeparatelyWrittenCopiesOfANoteAreTheSameNote()
    {
        void Markup(PdfAnnotationWriter w, PdfPage p) => w.AddNote(p, Box, new AnnotationInfo("a", "text"));
        Assert.True(Run(Markup, Markup).IsIdentical);
    }
}
