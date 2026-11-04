using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TextBoxTests
{
    private const string Words = "The quick brown fox jumps over the lazy dog and keeps running until the end of the day";

    [Fact]
    public void TextWrapsInsideTheBoxFromItsTop()
    {
        var session = EditKit.Session("");
        var result = new PageEditor(session, 0).AddTextBox(new PdfRect(100, 500, 250, 600), Words, new TextBoxStyle(Size: 12));
        Assert.True(result.Done, result.Problem);
        Assert.False(result.Overlaps);
        var text = TextPage.Create(session.Document, session.Document.Pages[0]);
        Assert.True(text.Lines.Count > 2);
        Assert.Equal(Words, string.Join(" ", text.Lines.Select(l => l.Text)));
        Assert.All(text.Lines, l =>
        {
            Assert.True(l.Bounds.Left >= 99.9 && l.Bounds.Right <= 250.1, l.Text);
            Assert.True(l.Bounds.Top <= 600.5);
        });
        Assert.Contains("quick brown", EditKit.Pig(session));
    }

    [Fact]
    public void ATallTextIsReportedAsTooLarge()
    {
        var session = EditKit.Session("");
        var result = new PageEditor(session, 0).AddTextBox(new PdfRect(100, 580, 250, 600), Words);
        Assert.True(result.Done);
        Assert.True(result.Overlaps);
    }

    [Fact]
    public void TurkishTextUsesTheFontSource()
    {
        var session = EditKit.Session("");
        var result = new PageEditor(session, 0, new EditArialSource()).AddTextBox(new PdfRect(50, 600, 400, 700), "Çalışma ğüzel İstanbul şehri", new TextBoxStyle(Family: "Arial", Size: 14));
        Assert.True(result.Done, result.Problem);
        Assert.Contains("Çalışma ğüzel İstanbul şehri", EditKit.Text(session));
        Assert.Contains("ğüzel", EditKit.Pig(session));
    }

    [Theory]
    [InlineData(TextAlignment.Left)]
    [InlineData(TextAlignment.Center)]
    [InlineData(TextAlignment.Right)]
    public void LinesFollowTheAlignment(TextAlignment alignment)
    {
        var session = EditKit.Session("");
        new PageEditor(session, 0).AddTextBox(new PdfRect(100, 500, 300, 600), "short\na somewhat longer line", new TextBoxStyle(Alignment: alignment));
        var lines = TextPage.Create(session.Document, session.Document.Pages[0]).Lines.OrderByDescending(l => l.Bounds.Top).ToList();
        double Edge(PageLine l) => alignment switch { TextAlignment.Right => l.Bounds.Right, TextAlignment.Center => (l.Bounds.Left + l.Bounds.Right) / 2, _ => l.Bounds.Left };
        Assert.Equal(Edge(lines[0]), Edge(lines[1]), 1);
    }

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void OnARotatedPageTheTextReadsUprightAsShown(int rotate)
    {
        var session = EditKit.Session("", $"/Rotate {rotate}");
        var shown = new PageGeometry(session.Document.Pages[0]);
        var box = shown.ToUser(new DisplayRect(100, 100, 200, 60));
        var result = new PageEditor(session, 0).AddTextBox(box, "Upright text");
        Assert.True(result.Done, result.Problem);
        var glyphs = EditKit.Glyphs(session);
        Assert.Equal("Upright text", string.Concat(glyphs.Select(g => g.Text)));
        var points = glyphs.Select(g => shown.ToDisplay(g.X, g.Y)).ToList();
        for (int i = 1; i < points.Count; i++)
        {
            Assert.True(points[i].X > points[i - 1].X - 0.01);
            Assert.Equal(points[0].Y, points[i].Y, 2);
        }
        Assert.InRange(points[0].X, 99.9, 101);
    }

    [Fact]
    public void ABoxWithNoAreaOrNoTextIsRefused()
    {
        var session = EditKit.Session("");
        var editor = new PageEditor(session, 0);
        Assert.False(editor.AddTextBox(new PdfRect(10, 10, 10, 50), "x").Done);
        Assert.False(editor.AddTextBox(new PdfRect(10, 10, 50, 50), "").Done);
        Assert.False(session.CanUndo);
    }
}
