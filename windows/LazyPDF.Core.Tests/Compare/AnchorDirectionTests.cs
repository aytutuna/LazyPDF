using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AnchorDirectionTests
{
    // Codes 1 to 6 are Hebrew letters; the text is set in visual order, so the first letter of a word is its rightmost glyph.
    private static PdfDocument Make(string line) =>
        TextTestPdf.Page(TextTestPdf.Line(100, 700, line), "", (1, "א"), (2, "ב"), (3, "ג"), (4, "ד"), (5, "ה"), (6, "ו"));

    [Fact]
    public void InsertionBetweenHebrewWordsOfALeftToRightLineIsAnchoredAtTheLeftEdgeOfTheEarlierOne()
    {
        using var before = Make(@"abc \004\003 \002\001 def");
        using var after = Make(@"abc \004\003 \006\005 \002\001 def");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Added, change.Kind);
        // The earlier word is read first and drawn on the right, from 135 to 145; its end is its left edge.
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Left, 134, 136);
    }

    [Fact]
    public void InsertionBetweenLatinWordsOfARightToLeftLineIsAnchoredAtTheRightEdgeOfTheEarlierOne()
    {
        using var before = Make(@"\004\003\002\001 ab cd \004\003\002\001");
        using var after = Make(@"\004\003\002\001 ab xy cd \004\003\002\001");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Added, change.Kind);
        // 'ab' is drawn from 125 to 135.
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Left, 134, 136);
    }
}
