using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Content added to a page runs after the page's own, whatever state that leaves behind, and stays at its level for Order.
public class AddedContentTests
{
    private static readonly RgbColor Red = new(255, 0, 0), Green = new(0, 255, 0), Blue = new(0, 0, 255);

    private static List<RgbColor> Fills(PdfEditSession session) => EditPaint.Paths(session).Select(p => p.Fill).ToList();

    [Fact]
    public void AStrayRestoreDoesNotPopAWrapperAndAddedTextStartsFromTheIdentityMatrix()
    {
        var session = EditKit.Session("1 0 0 1 100 0 cm Q BT /F1 12 Tf 50 700 Td (page) Tj ET 2 0 0 2 0 0 cm");
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0, new EditArialSource()).AddTextBox(new PdfRect(100, 300, 300, 400), "new");
        Assert.True(result.Done, result.Problem);
        var after = EditKit.Glyphs(session);
        Assert.Equal(before, after.Take(before.Count));
        var added = after[before.Count];
        Assert.Equal(100, added.X, 0);
        Assert.Equal(12, added.Size, 1);
    }

    [Fact]
    public void ACleanPageGetsNoWrapperAroundItsContent()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        new PageEditor(session, 0).AddRectangle(new PdfRect(100, 100, 150, 150), new ShapeStyle(null, Blue));
        var streams = session.Document.Pages[0].Dictionary["Contents"] as PdfArray;
        Assert.Equal(2, streams!.Items.Count);
        Assert.Equal("q 1 0 0 rg 0 0 50 50 re f Q", EditKit.Latin(session).Split('\n')[0]);
    }

    [Fact]
    public void OrderPassesAnAddedShapeOnACleanPage()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q q 0 1 0 rg 100 0 50 50 re f Q");
        var editor = new PageEditor(session, 0);
        Assert.True(editor.AddRectangle(new PdfRect(200, 0, 250, 50), new ShapeStyle(null, Blue)).Done);
        Assert.Equal([Red, Green, Blue], Fills(session));
        var green = editor.Objects.OfType<PathObject>().ToList()[1];
        Assert.True(editor.Order(green, OrderMove.Front).Done);
        Assert.Equal([Red, Blue, Green], Fills(session));
    }

    [Fact]
    public void OrderSwapsTwoAddedShapes()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0);
        editor.AddRectangle(new PdfRect(100, 0, 150, 50), new ShapeStyle(null, Green));
        editor.AddRectangle(new PdfRect(200, 0, 250, 50), new ShapeStyle(null, Blue));
        var shapes = editor.Objects.OfType<PathObject>().ToList();
        Assert.Equal(3, shapes.Count);
        Assert.True(editor.Order(shapes[1], OrderMove.Forward).Done);
        Assert.Equal([Red, Blue, Green], Fills(session));
    }

    [Fact]
    public void OrderStaysBehindTextThatClipsAtItsEnd()
    {
        string content = "q 1 0 0 rg 0 0 50 50 re f Q BT /F1 40 Tf 7 Tr 0 0 Td (XX) Tj ET q 0 0 1 rg 0 0 50 50 re f Q";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var paths = editor.Objects.OfType<PathObject>().ToList();
        Assert.False(editor.Order(paths[1], OrderMove.Back).Done);
        Assert.Equal(content, EditKit.Latin(session));
    }

    [Fact]
    public void TextIsNotArranged()
    {
        string content = "BT /F1 12 Tf 50 700 Td (Hello) Tj ET";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var result = editor.Order(Assert.Single(editor.Objects.OfType<TextObject>()), OrderMove.Front);
        Assert.False(result.Done);
        Assert.Equal(EditingText.NotAlone, Assert.Single(result.Skipped).Reason);
        Assert.Equal(content, EditKit.Latin(session));
    }
}
