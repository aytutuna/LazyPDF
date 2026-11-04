using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A text block is moved with a matrix round its operators, leaving its coordinates and the rest of the text object alone.
public class TextMoveTests
{
    private const string Two = "BT /F1 12 Tf 50 700 Td (Block one line a) Tj 0 -14 Td (line b of one) Tj 0 -150 Td (Block two) Tj ET";

    private static void AssertMoved(List<EditGlyphAt> before, List<EditGlyphAt> after, Func<int, bool> moved, double dx, double dy)
    {
        Assert.Equal(before.Count, after.Count);
        for (int i = 0; i < before.Count; i++)
        {
            Assert.Equal(before[i].Text, after[i].Text);
            Assert.Equal(before[i].X + (moved(i) ? dx : 0), after[i].X, 2);
            Assert.Equal(before[i].Y + (moved(i) ? dy : 0), after[i].Y, 2);
        }
    }

    private static List<TextObject> Blocks(PageEditor editor) => [.. editor.Objects.OfType<TextObject>().OrderByDescending(b => b.Bounds.Top)];

    [Fact]
    public void OneBlockOfTwoInOneTextObjectMovesAlone()
    {
        var session = EditKit.Session(Two);
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var blocks = Blocks(editor);
        Assert.Equal(2, blocks.Count);
        Assert.True(editor.Move([blocks[0]], 40, -20).Done);
        AssertMoved(before, EditKit.Glyphs(session), i => i < 29, 40, -20);
    }

    [Fact]
    public void TheLastBlockMovesAndTheTextObjectStillEnds()
    {
        var session = EditKit.Session(Two);
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        Assert.True(editor.Move([Blocks(editor)[1]], -10, 30).Done);
        AssertMoved(before, EditKit.Glyphs(session), i => i >= 29, -10, 30);
        Assert.Contains("Block two", EditKit.Pig(session));
    }

    [Fact]
    public void BothBlocksMoveByTheirOwnMatrices()
    {
        var session = EditKit.Session(Two);
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var result = editor.Move(editor.Objects, 5, 5);
        Assert.Equal(2, result.Changed);
        AssertMoved(before, EditKit.Glyphs(session), _ => true, 5, 5);
    }

    [Fact]
    public void TextShownWithQuoteOperatorsAndKerningMoves()
    {
        var session = EditKit.Session("BT /F1 12 Tf 14 TL 50 700 Td [(Kern) -300 (ed) 120 (text)] TJ (second line) ' (third line) ' ET\nBT 1 0 0 1 50 300 Tm (other) Tj ET");
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var block = Blocks(editor)[0];
        Assert.True(editor.Move([block], 15, 5).Done);
        AssertMoved(before, EditKit.Glyphs(session), i => i < before.Count - 5, 15, 5);
    }

    [Fact]
    public void ABlockInTheMiddleOfARunIsLeftWhereItIs()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (left) Tj 100 0 Td (middle) Tj 100 0 Td (right) Tj ET");
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var middle = editor.Objects.OfType<TextObject>().First(b => b.Text.Contains("middle"));
        Assert.True(editor.Move([middle], 0, -50).Done);
        AssertMoved(before, EditKit.Glyphs(session), i => i is >= 4 and < 10, 0, -50);
    }

    [Fact]
    public void ABlockThatIsPartOfAStringIsMovedByCuttingTheString()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td [(Name:) -6000 (value) -250 (here)] TJ 0 -14 Td (next line) Tj ET");
        var editor = new PageEditor(session, 0);
        var before = EditKit.Glyphs(session);
        var cells = editor.Objects.OfType<TextObject>().Where(b => b.Bounds.Top > 690).OrderBy(b => b.Bounds.Left).ToList();
        Assert.Equal(2, cells.Count);
        var result = editor.Move([cells[1]], 0, -60);
        Assert.True(result.Done, string.Join(", ", result.Skipped.Select(s => s.Reason)));
        var after = EditKit.Glyphs(session);
        Assert.Equal(before.Count, after.Count);
        for (int i = 0; i < before.Count; i++)
        {
            bool moved = i is >= 5 and < 14;
            Assert.Equal(before[i].X, after[i].X, 2);
            Assert.Equal(before[i].Y + (moved ? -60 : 0), after[i].Y, 2);
        }
    }

    [Fact]
    public void ScalingAndRotatingATextBlockTransformsEachGlyph()
    {
        var session = EditKit.Session("BT /F1 12 Tf 100 700 Td (turn me) Tj ET");
        var editor = new PageEditor(session, 0);
        var box = editor.Objects[0].Bounds;
        Assert.True(editor.Rotate(editor.Objects, 90).Done);
        var glyphs = EditKit.Glyphs(session);
        // Turned a quarter, the baseline runs up the page.
        Assert.True(glyphs[^1].Y > glyphs[0].Y + 10);
        Assert.Equal(glyphs[0].X, glyphs[^1].X, 2);
        Assert.Equal("turn me", string.Concat(glyphs.Select(g => g.Text)));
        var center = new PageEditor(session, 0).Objects[0].Bounds;
        Assert.Equal((box.Left + box.Right) / 2, (center.Left + center.Right) / 2, 1);
        Assert.Equal((box.Bottom + box.Top) / 2, (center.Bottom + center.Top) / 2, 1);
    }

    [Fact]
    public void TextWithAnOpenQLevelIsRefusedNotBroken()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (hello) Tj q ET Q BT 0 -14 Td (world) Tj ET");
        var editor = new PageEditor(session, 0);
        string before = EditKit.Latin(session);
        var hello = editor.Objects.OfType<TextObject>().First(b => b.Text.StartsWith("hello"));
        var result = editor.Move([hello], 10, 10);
        Assert.False(result.Done);
        Assert.Equal(EditingText.Unbalanced, Assert.Single(result.Skipped).Reason);
        Assert.Equal(before, EditKit.Latin(session));
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void DeleteTakesABlockOutAndLeavesTheOthers()
    {
        var session = EditKit.Session(Two);
        var editor = new PageEditor(session, 0);
        Assert.True(editor.Delete([Blocks(editor)[0]]).Done);
        Assert.Equal("Block two", EditKit.Text(session).Trim());
        Assert.Equal(Math.Round(50.0, 3), EditKit.Glyphs(session)[0].X);
    }
}
