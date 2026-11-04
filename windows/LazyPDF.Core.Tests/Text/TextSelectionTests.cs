using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextSelectionTests
{
    // Glyph i of the first line is at 100 + 5 i; the lines are 12 points apart.
    private static TextPage Sample() =>
        Text(Line(100, 700, "hello brave world") + Line(100, 688, "second line here") + Line(100, 676, "third"));

    [Fact]
    public void ADragSelectsFromCaretToCaret()
    {
        var page = Sample();
        var selection = TextSelection.Between(page, 131, 702, 168, 702);
        Assert.Equal("brave wo", selection.GetText());
        Assert.Equal(new TextRange(6, 14), selection.Ranges[0]);
    }

    [Fact]
    public void TheDragCanGoBackwards()
    {
        var page = Sample();
        Assert.Equal("brave wo", TextSelection.Between(page, 168, 702, 131, 702).GetText());
    }

    [Fact]
    public void ADragAcrossLinesTakesTheLineBreak()
    {
        var page = Sample();
        Assert.Equal("world\nsecond", TextSelection.Between(page, 161, 702, 133, 690).GetText());
    }

    [Fact]
    public void APointOutsideTheTextStillFindsACaret()
    {
        var page = Sample();
        Assert.Equal(0, page.CaretAt(10, 790));
        Assert.Equal(page.Chars.Count, page.CaretAt(500, 10));
        Assert.Equal("hello brave world\nsecond line here\nthird", TextSelection.Between(page, 0, 799, 599, 0).GetText());
    }

    [Fact]
    public void ARectangleTakesTheCharactersInsideIt()
    {
        var page = Sample();
        var selection = TextSelection.InRectangle(page, new PdfRect(95, 685, 400, 698));
        Assert.Equal("second line here", selection.GetText());
        var part = TextSelection.InRectangle(page, new PdfRect(99, 685, 131, 698));
        Assert.Equal("second", part.GetText());
    }

    [Fact]
    public void ARectangleWithoutTextIsEmpty()
    {
        var selection = TextSelection.InRectangle(Sample(), new PdfRect(400, 100, 500, 200));
        Assert.True(selection.IsEmpty);
        Assert.Equal("", selection.GetText());
        Assert.Empty(selection.Quads());
    }

    [Fact]
    public void ADoubleClickSelectsAWordAndATripleClickALine()
    {
        var page = Sample();
        Assert.Equal("brave", TextSelection.WordAt(page, 142, 702).GetText());
        Assert.Equal("hello brave world", TextSelection.LineAt(page, 142, 702).GetText());
        Assert.Equal("second", TextSelection.WordAt(page, 101, 690).GetText());
    }

    [Fact]
    public void ADoubleClickOnASpaceTakesTheNextWord()
    {
        var page = Sample();
        Assert.Equal("brave", TextSelection.WordAt(page, 127.5, 702).GetText());
    }

    [Fact]
    public void QuadsComeOnePerLine()
    {
        var page = Sample();
        var quads = TextSelection.Between(page, 161, 702, 133, 690).Quads();
        Assert.Equal(2, quads.Count);
        Assert.Equal(160, quads[0].Bounds.Left, 6);
        Assert.Equal(185, quads[0].Bounds.Right, 6);
        Assert.Equal(100, quads[1].Bounds.Left, 6);
        Assert.Equal(130, quads[1].Bounds.Right, 6);
        Assert.True(quads[0].Bounds.Bottom > quads[1].Bounds.Top - 1);
    }

    [Fact]
    public void QuadsLeaveOutSpacesAtTheEnds()
    {
        var page = Sample();
        var quads = page.Quads(new TextRange(5, 12));
        Assert.Single(quads);
        Assert.Equal(130, quads[0].Bounds.Left, 6);
        Assert.Equal(155, quads[0].Bounds.Right, 6);
    }

    [Fact]
    public void QuadsOfRotatedTextAreRotated()
    {
        var page = Text("BT /F1 10 Tf 0 1 -1 0 300 300 Tm (up and away) Tj ET");
        var q = page.Quads(new TextRange(0, page.Chars.Count)).Single();
        Assert.Equal(q.X0, q.X1, 6);
        Assert.True(q.Y1 > q.Y0);
        var points = q.ToQuadPoints();
        Assert.Equal(8, points.Length);
    }

    [Fact]
    public void AHitGivesTheNearestCharacterWordAndLine()
    {
        var page = Sample();
        var hit = page.HitTest(142, 702)!.Value;
        Assert.Equal(0, hit.Distance);
        Assert.Equal("a", page.Chars[hit.Char].Text);
        Assert.Equal("brave", page.Words[hit.Word].Text);
        Assert.Equal(0, hit.Line);
        var near = page.HitTest(98, 702)!.Value;
        Assert.Equal(0, near.Char);
        Assert.Equal(2, near.Distance, 6);
    }

    [Fact]
    public void AHitFartherThanTheLimitIsNull()
    {
        var page = Sample();
        Assert.Null(page.HitTest(400, 400, 20));
        Assert.NotNull(page.HitTest(400, 400));
        Assert.Null(Text("").HitTest(10, 10));
    }

    [Fact]
    public void TheNearestLineWinsBetweenTwoLines()
    {
        var page = Sample();
        Assert.Equal(1, page.HitTest(150, 686)!.Value.Line);
        Assert.Equal(0, page.HitTest(150, 697)!.Value.Line);
    }

    [Fact]
    public void LigaturesAreSelectedWhole()
    {
        var page = Text(Line(100, 700, @"\001nd"), "", (1, "fi"));
        var selection = TextSelection.Between(page, 102, 702, 112, 702);
        Assert.Equal("find", TextSelection.WordAt(page, 101, 702).GetText());
        Assert.Equal("fi", page.GetText(new TextRange(0, 1)));
        Assert.False(selection.IsEmpty);
    }

    [Fact]
    public void SelectionTextCanJoinHyphens()
    {
        var page = Text(Line(100, 700, "an informa-") + Line(100, 688, "tion line"));
        var all = TextSelection.Of(page, new TextRange(0, page.Chars.Count));
        Assert.Equal("an informa-\ntion line", all.GetText());
        Assert.Equal("an information line", all.GetText(joinHyphens: true));
    }
}
