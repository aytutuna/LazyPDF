using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ParagraphTests
{
    private static readonly string[] Lines =
    [
        "The quick brown fox jumps over",
        "the lazy dog and keeps running",
        "until the end of the day",
    ];

    private static double Width(string text) =>
        new PdfFontEmbedder(PdfDocument.Open(TestPdf.Simple(1))).Add("Helvetica", FontStyles.Regular, [text])!.Width(text, 12);

    private static PdfEditSession Left() =>
        EditKit.Session("BT /F1 12 Tf 14 TL 50 700 Td (" + Lines[0] + ") Tj T* (" + Lines[1] + ") Tj T* (" + Lines[2] + ") Tj ET");

    private static PdfEditSession Aligned(Func<string, double> x)
    {
        var content = "BT /F1 12 Tf 1 0 0 1 0 0 Tm ";
        for (int i = 0; i < Lines.Length; i++) content += $"1 0 0 1 {x(Lines[i]):0.###} {700 - 14 * i} Tm ({Lines[i]}) Tj ";
        return EditKit.Session(content + "ET");
    }

    private static TextObject Block(PageEditor editor) => Assert.Single(editor.Objects.OfType<TextObject>());

    private static List<string> Rows(PdfEditSession session) =>
        [.. TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).Select(l => l.Text)];

    [Fact]
    public void TheBlockIsOneParagraphWithItsStyle()
    {
        var block = Block(new PageEditor(Left(), 0));
        Assert.Equal(3, block.Lines.Count);
        Assert.Equal(TextAlignment.Left, block.Alignment);
        Assert.Equal(14, block.LineSpacing, 1);
        Assert.Equal(12, block.Size, 3);
        Assert.Equal("Helvetica", block.Font!.Name);
    }

    [Fact]
    public void LongerTextWrapsInsideTheWidthAndTheBlockGrows()
    {
        var session = Left();
        var editor = new PageEditor(session, 0);
        double room = Lines.Max(Width);
        string text = "The quick brown fox jumps over the lazy dog and keeps running until the end of the day, then it sleeps under a tree until the sun is up again";
        var result = editor.ReplaceParagraph(Block(editor), text);
        Assert.True(result.Done, result.Problem);
        Assert.True(result.Grew);
        var rows = Rows(session);
        Assert.True(rows.Count > 3);
        Assert.Equal(text, string.Join(" ", rows));
        Assert.All(rows, r => Assert.True(Width(r) <= room + 0.5, r));
        string pig = EditKit.Pig(session);
        Assert.All(rows, r => Assert.Contains(r, pig));
    }

    [Fact]
    public void ShorterTextRemovesTheLinesItDoesNotNeed()
    {
        var session = Left();
        var editor = new PageEditor(session, 0);
        var result = editor.ReplaceParagraph(Block(editor), "Just one short line");
        Assert.True(result.Done, result.Problem);
        Assert.False(result.Grew);
        Assert.Equal(["Just one short line"], Rows(session));
    }

    [Fact]
    public void HardBreaksStartNewLines()
    {
        var session = Left();
        var editor = new PageEditor(session, 0);
        editor.ReplaceParagraph(Block(editor), "one\ntwo\n\nthree");
        Assert.Equal(["one", "two", "three"], Rows(session));
    }

    [Fact]
    public void CenteredLinesStayCentered()
    {
        var session = Aligned(l => 300 - Width(l) / 2);
        var editor = new PageEditor(session, 0);
        var block = Block(editor);
        Assert.Equal(TextAlignment.Center, block.Alignment);
        var result = editor.ReplaceParagraph(block, "short top\nand a much longer second line of words");
        Assert.True(result.Done, result.Problem);
        foreach (var line in TextPage.Create(session.Document, session.Document.Pages[0]).Lines)
        {
            Assert.Equal(300, (line.Bounds.Left + line.Bounds.Right) / 2, 1);
        }
    }

    [Fact]
    public void RightAlignedLinesKeepTheirRightEdge()
    {
        var session = Aligned(l => 500 - Width(l));
        var editor = new PageEditor(session, 0);
        var block = Block(editor);
        Assert.Equal(TextAlignment.Right, block.Alignment);
        var result = editor.ReplaceParagraph(block, "a little\nand a much longer second line");
        Assert.True(result.Done, result.Problem);
        foreach (var line in TextPage.Create(session.Document, session.Document.Pages[0]).Lines) Assert.Equal(500, line.Bounds.Right, 1);
    }

    [Fact]
    public void ReplacingACenteredLineKeepsItCentered()
    {
        var session = Aligned(l => 300 - Width(l) / 2);
        var editor = new PageEditor(session, 0);
        var result = editor.ReplaceText(editor.Text.Lines[1].Range, "x");
        Assert.True(result.Done, result.Problem);
        var line = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.First(l => l.Text == "x");
        Assert.Equal(300, (line.Bounds.Left + line.Bounds.Right) / 2, 1);
    }

    [Theory]
    [InlineData(TextAlignment.Right)]
    [InlineData(TextAlignment.Center)]
    [InlineData(TextAlignment.Left)]
    public void AlignmentMovesTheLines(TextAlignment target)
    {
        var session = target == TextAlignment.Left ? Aligned(l => 500 - Width(l)) : Left();
        var editor = new PageEditor(session, 0);
        var result = editor.SetAlignment(Block(editor), target);
        Assert.True(result.Done, result.Problem);
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines;
        var block = Block(new PageEditor(session, 0));
        Assert.Equal(target, block.Alignment);
        Assert.Equal(Lines, Rows(session));
        double Edge(PageLine l) => target switch { TextAlignment.Right => l.Bounds.Right, TextAlignment.Center => (l.Bounds.Left + l.Bounds.Right) / 2, _ => l.Bounds.Left };
        Assert.True(lines.Max(Edge) - lines.Min(Edge) < 0.5);
    }

    [Fact]
    public void JustifyFillsTheWidthOfAllButTheLastLine()
    {
        var session = Left();
        var editor = new PageEditor(session, 0);
        Assert.True(editor.SetAlignment(Block(editor), TextAlignment.Justify).Done);
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).ToList();
        Assert.Equal(lines[0].Bounds.Right, lines[1].Bounds.Right, 1);
        Assert.True(lines[2].Bounds.Right < lines[1].Bounds.Right - 5);
        Assert.Equal(Lines, Rows(session));
    }

    [Fact]
    public void LineSpacingMovesTheLinesAndLeavesTheTextAlone()
    {
        var session = Left();
        var editor = new PageEditor(session, 0);
        Assert.True(editor.SetLineSpacing(Block(editor), 20).Done);
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).ToList();
        Assert.Equal(20, lines[0].Bounds.Top - lines[1].Bounds.Top, 1);
        Assert.Equal(20, lines[1].Bounds.Top - lines[2].Bounds.Top, 1);
        Assert.Equal(Lines, Rows(session));
        Assert.Equal(20, Block(new PageEditor(session, 0)).LineSpacing, 1);
    }
}
