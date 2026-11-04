using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Justify and line spacing on lines whose strings are placed one by one, drawn twice, or drawn out of reading order.
public class LineSetTests
{
    private static TextObject Block(PageEditor editor) => editor.Objects.OfType<TextObject>().First();

    [Fact]
    public void JustifyMovesAStringThatTdPlacesBehindTheSpacesBeforeIt()
    {
        var session = EditKit.Session("BT /F1 12 Tf 14 TL 50 700 Td (Hello ) Tj 31 0 Td (World) Tj -31 -14 Td (a much longer second line here) Tj ET");
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var result = editor.SetAlignment(Block(editor), TextAlignment.Justify);
        Assert.True(result.Done, result.Problem);
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).ToList();
        Assert.Equal(lines[^1].Bounds.Right, lines.Where(l => l.Bounds.Top > 690).Max(l => l.Bounds.Right), 1);
        var after = EditKit.Glyphs(session);
        Assert.True(after[6].X > before[6].X + 20);
    }

    [Fact]
    public void LineSpacingMovesBothStrikesOfADoubleStruckLine()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (first line) Tj ET BT /F1 12 Tf 50 686 Td (second) Tj ET BT /F1 12 Tf 50.2 686 Td (second) Tj ET");
        var editor = new PageEditor(session, 0);
        Assert.True(editor.SetLineSpacing(Block(editor), 30).Done);
        var second = EditKit.Glyphs(session).Where(g => g.Text == "s" && g.Y < 690).ToList();
        Assert.Equal(2, second.Count);
        Assert.All(second, g => Assert.Equal(670, g.Y, 1));
    }

    [Fact]
    public void JustifyOfLinesDrawnOutOfOrderLeavesTheWordSpacingOfTheRestAlone()
    {
        string content = "BT /F1 12 Tf 50 686 Td (line two is a longer one) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 100 Td (tail text) Tj ET";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var result = editor.SetAlignment(Block(editor), TextAlignment.Justify);
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.True(EditKit.Of(shown, "line one").First(g => g.Text == " ").Tw > 0);
        Assert.All(EditKit.Of(shown, "line two is"), g => Assert.Equal(0, g.Tw));
        Assert.All(EditKit.Of(shown, "tail text"), g => Assert.Equal(0, g.Tw));
    }

    [Fact]
    public void LineSpacingOfLinesDrawnOutOfOrderLeavesTheRiseOfTheRestAlone()
    {
        string content = "BT /F1 12 Tf 50 672 Td (line three) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 686 Td (line two) Tj ET BT /F1 12 Tf 50 100 Td (tail) Tj ET";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        Assert.True(editor.SetLineSpacing(Block(editor), 20).Done);
        var shown = EditKit.Shown(session);
        Assert.Equal(660, EditKit.Of(shown, "line three")[0].Y, 1);
        Assert.Equal(680, EditKit.Of(shown, "line two")[0].Y, 1);
        Assert.Equal(100, EditKit.Of(shown, "tail")[0].Y, 1);
    }
}
