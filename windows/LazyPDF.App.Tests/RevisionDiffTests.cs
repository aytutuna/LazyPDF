using System.Text;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Which pages an edit can have changed, found from the bytes the edit session appended.
public sealed class RevisionDiffTests
{
    private static byte[] Ascii(string text) => Encoding.ASCII.GetBytes(text);

    [Fact]
    public void TheObjectsDefinedInTheAppendedPartAreTheChangedOnes()
    {
        var before = Ascii("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n");
        byte[] after = [.. before, .. Ascii("12 0 obj\n<< /A 1 >>\nendobj\n7 3 obj\n(x)\nendobj\nxref\n")];

        var changed = RevisionDiff.Changed(before, after);

        Assert.Equal([7, 12], changed!.Order());
    }

    [Fact]
    public void TheSameObjectsAreFoundWhenTheLongerBufferIsTheOldOne()
    {
        var shorter = Ascii("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n");
        byte[] longer = [.. shorter, .. Ascii("5 0 obj\n<<>>\nendobj\n")];

        Assert.Equal([5], RevisionDiff.Changed(longer, shorter)!);
    }

    [Fact]
    public void BuffersWhereNeitherBeginsWithTheOtherAreAllChanged()
    {
        Assert.Null(RevisionDiff.Changed(Ascii("%PDF-1.7 one"), Ascii("%PDF-1.7 two, longer")));
    }

    [Fact]
    public void IdenticalBuffersChangeNothing()
    {
        Assert.Empty(RevisionDiff.Changed(Ascii("%PDF-1.7\n1 0 obj\n"), Ascii("%PDF-1.7\n1 0 obj\n"))!);
    }

    [Fact]
    public void ATitleChangeTouchesNoPage()
    {
        var session = PdfEditSession.Open(Pdfs.Text(pages: 2));
        var before = session.Current.ToArray();
        Pdfs.Retitle(session, "Another title");
        session.Commit("Title");

        var changed = RevisionDiff.Changed(before, session.Current.Span)!;

        Assert.NotEmpty(changed);
        Assert.False(RevisionDiff.Touches(session.Document, session.Document.Pages[0], changed));
        Assert.False(RevisionDiff.Touches(session.Document, session.Document.Pages[1], changed));
    }

    [Fact]
    public void ANoteOnOnePageTouchesThatPageOnly()
    {
        var session = PdfEditSession.Open(Pdfs.Text(pages: 3));
        var before = session.Current.ToArray();
        new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[1], new PdfRect(100, 100, 120, 120), new AnnotationInfo("Ada", "Look", null, DateTimeOffset.UnixEpoch));
        session.Commit("Note");

        var changed = RevisionDiff.Changed(before, session.Current.Span)!;

        var document = session.Document;
        Assert.False(RevisionDiff.Touches(document, document.Pages[0], changed));
        Assert.True(RevisionDiff.Touches(document, document.Pages[1], changed));
        Assert.False(RevisionDiff.Touches(document, document.Pages[2], changed));
    }

    [Fact]
    public void UndoFindsTheSamePage()
    {
        var session = PdfEditSession.Open(Pdfs.Text(pages: 2));
        new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[0], new PdfRect(100, 100, 120, 120), new AnnotationInfo("Ada", "Look", null, DateTimeOffset.UnixEpoch));
        session.Commit("Note");
        var committed = session.Current.ToArray();

        session.Undo();
        var changed = RevisionDiff.Changed(committed, session.Current.Span)!;

        Assert.True(RevisionDiff.Touches(session.Document, session.Document.Pages[0], changed));
        Assert.False(RevisionDiff.Touches(session.Document, session.Document.Pages[1], changed));
    }

    // The page draws a form XObject that its resource dictionary names /P, a key the walk skips in a page's own dictionary.
    private static PdfDocument PageWithResourceNamedP() => PdfDocument.Open(Encoding.ASCII.GetBytes(
        "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /P 5 0 R /Parent 6 0 R >> >> /Contents 4 0 R >>\nendobj\n"
        + "4 0 obj\n<< /Length 5 >>\nstream\n/P Do\nendstream\nendobj\n"
        + "5 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length 0 >>\nstream\n\nendstream\nendobj\n"
        + "6 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length 0 >>\nstream\n\nendstream\nendobj\n"
        + "trailer\n<< /Root 1 0 R /Size 7 >>\n%%EOF\n"));

    [Theory]
    [InlineData(5)]
    [InlineData(6)]
    public void AResourceNamedLikeALeavingKeyIsStillFollowed(int changedObject)
    {
        var document = PageWithResourceNamedP();

        Assert.True(RevisionDiff.Touches(document, document.Pages[0], [changedObject]));
    }

    [Fact]
    public void AnObjectNoPageUsesTouchesNothing()
    {
        var document = PageWithResourceNamedP();

        Assert.False(RevisionDiff.Touches(document, document.Pages[0], [99]));
    }

    [Fact]
    public void AWalkThatRunsOutOfBudgetCountsAsTouched()
    {
        var file = new StringBuilder("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
        string refs = string.Join(" ", Enumerable.Range(10, 6000).Select(n => n + " 0 R"));
        file.Append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources << /Other [" + refs + "] >> >>\nendobj\n");
        foreach (int n in Enumerable.Range(10, 6000)) file.Append(n + " 0 obj\n<< >>\nendobj\n");
        file.Append("trailer\n<< /Root 1 0 R /Size 6010 >>\n%%EOF\n");
        var document = PdfDocument.Open(Encoding.ASCII.GetBytes(file.ToString()));

        Assert.True(RevisionDiff.Touches(document, document.Pages[0], [99999]));
    }

    [Fact]
    public void ASaveWithoutHistoryIsASeparateFile()
    {
        using var dir = new TempDir();
        var session = PdfEditSession.Open(Pdfs.Text(pages: 2));
        Pdfs.Retitle(session, "Titled");
        session.Commit("Title");
        var before = session.Current.ToArray();

        session.SaveCompact(dir.File("small.pdf", []));

        Assert.Null(RevisionDiff.Changed(before, session.Current.Span));
    }
}
