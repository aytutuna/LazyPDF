using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Edits put operators round text and objects; none of them may change what the content around them draws.
public class StateLeakTests
{
    private sealed record Shown(string Text, double X, double Y, RgbColor Color, double Tc, double Tw, int Mode, double Size);

    private sealed class Probe(List<Shown> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            var s = context.State;
            found.Add(new Shown(glyph.Unicode ?? "", Math.Round(glyph.Matrix.E, 2), Math.Round(glyph.Matrix.F, 2), s.FillColor.Rgb, s.CharSpacing, s.WordSpacing, s.RenderMode, Math.Round(glyph.Matrix.D, 2)));
        }
    }

    private static List<Shown> Read(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = new List<Shown>();
        new ContentInterpreter(document).Run(document.Pages[0], new Probe(found));
        return found;
    }

    private static List<Shown> Of(List<Shown> shown, string word)
    {
        int at = string.Concat(shown.Select(s => s.Text)).IndexOf(word, StringComparison.Ordinal);
        Assert.True(at >= 0, word);
        return shown.GetRange(at, word.Length);
    }

    private static readonly RgbColor Red = new(255, 0, 0);

    [Fact]
    public void RestyleOfLinesDrawnOutOfReadingOrderLeavesTheRestAlone()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 680 Td (line two) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 100 Td (tail) Tj ET");
        var editor = new PageEditor(session, 0);
        var one = EditKit.Find(session, "line one");
        var two = EditKit.Find(session, "line two");
        var result = editor.SetTextStyle([new TextRange(one.Start, two.End)], new TextStyleChange(Color: Red));
        Assert.True(result.Done, result.Problem);
        var shown = Read(session);
        Assert.All(Of(shown, "line one"), g => Assert.Equal(Red, g.Color));
        Assert.All(Of(shown, "line two"), g => Assert.Equal(Red, g.Color));
        Assert.All(Of(shown, "tail"), g => Assert.Equal(default, g.Color));
    }

    [Fact]
    public void RestyleOfOneColumnLeavesTheOtherColumnAlone()
    {
        string content = "BT /F1 12 Tf 50 700 Td (left top) Tj 300 0 Td (right top) Tj -300 -20 Td (left low) Tj 300 0 Td (right low) Tj ET";
        var session = EditKit.Session(content);
        var editor = new PageEditor(session, 0);
        var a = EditKit.Find(session, "left top");
        var b = EditKit.Find(session, "left low");
        var result = editor.SetTextStyle([new TextRange(Math.Min(a.Start, b.Start), Math.Max(a.End, b.End))], new TextStyleChange(Color: Red));
        Assert.True(result.Done, result.Problem);
        var shown = Read(session);
        Assert.All(Of(shown, "left top"), g => Assert.Equal(Red, g.Color));
        Assert.All(Of(shown, "left low"), g => Assert.Equal(Red, g.Color));
        Assert.All(Of(shown, "right top"), g => Assert.Equal(default, g.Color));
        Assert.All(Of(shown, "right low"), g => Assert.Equal(default, g.Color));
    }

    [Fact]
    public void TextInAFormKeepsTheStateItInheritsWhenItIsRestyled()
    {
        var session = EditKit.Session("1 0 0 rg 0.5 Tc /Fm0 Do",
            more: pdf => pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET"),
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>>");
        var editor = new PageEditor(session, 0);
        var hello = EditKit.Find(session, "Hello");
        Assert.True(editor.SetTextStyle([hello], new TextStyleChange(CharSpacing: 0.25)).Done);
        var shown = Read(session);
        Assert.All(Of(shown, "Hello"), g => Assert.Equal(0.25, g.Tc));
        Assert.All(Of(shown, "World"), g =>
        {
            Assert.Equal(0.5, g.Tc);
            Assert.Equal(Red, g.Color);
        });
        editor.Refresh();
        Assert.True(editor.SetTextStyle([EditKit.Find(session, "Hello")], new TextStyleChange(Color: new RgbColor(0, 0, 255))).Done);
        Assert.All(Of(Read(session), "World"), g => Assert.Equal(Red, g.Color));
    }

    [Fact]
    public void AddedTextIsNotHiddenByRenderModeTheTopLevelLeft()
    {
        var session = EditKit.Session("BT /F1 12 Tf 3 Tr 50 700 Td (ocr layer) Tj ET");
        var result = new PageEditor(session, 0, new EditArialSource()).AddTextBox(new PdfRect(100, 300, 300, 400), "visible");
        Assert.True(result.Done, result.Problem);
        var added = Of(Read(session), "visible");
        Assert.All(added, g => Assert.Equal(0, g.Mode));
    }

    [Fact]
    public void AddedTextAndShapesStartFromTheDefaultState()
    {
        var session = EditKit.Session("BT /F1 12 Tf 2 Tc 3 Tw 50 700 Td (ocr layer) Tj ET 0 0 1 rg 0 0 600 800 re W n 1 0 0 1 10 10 cm");
        var editor = new PageEditor(session, 0, new EditArialSource());
        Assert.True(editor.AddTextBox(new PdfRect(100, 300, 300, 400), "visible").Done);
        var added = Of(Read(session), "visible");
        Assert.All(added, g =>
        {
            Assert.Equal(0, g.Tc);
            Assert.Equal(0, g.Tw);
            Assert.Equal(default, g.Color);
        });
        Assert.Equal(100, added[0].X, 0);
    }

    [Fact]
    public void QuoteOperatorSpacingSurvivesARestyleOfTheTextBefore()
    {
        var session = EditKit.Session("BT /F1 12 Tf 14 TL 50 700 Td 2 1 (abc) \" (def) Tj ( ghi) Tj ET");
        var editor = new PageEditor(session, 0);
        Assert.True(editor.SetTextStyle([EditKit.Find(session, "def")], new TextStyleChange(CharSpacing: 4)).Done);
        var shown = Read(session);
        Assert.All(Of(shown, "ghi"), g => Assert.Equal(1, g.Tc));
        Assert.All(Of(shown, "def"), g => Assert.Equal(4, g.Tc));
    }

    [Fact]
    public void OperatorsInsertedAtAnOperationStartAreSeparatedFromTheOperatorBefore()
    {
        var session = EditKit.Session("q 100 0 0 100 0 0 cm/Im0 Do Q",
            more: pdf => pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0]),
            resources: "/XObject <</Im0 7 0 R>>");
        var editor = new PageEditor(session, 0);
        var before = EditPaint.Images(session);
        Assert.True(editor.Move(editor.Objects.OfType<ImageObject>(), 30, 40).Done);
        var after = EditPaint.Images(session);
        Assert.Equal(before[0].Matrix.E + 30, after[0].Matrix.E, 3);
        Assert.Equal(before[0].Matrix.F + 40, after[0].Matrix.F, 3);
        Assert.Equal(100, after[0].Matrix.A, 3);
    }

    [Fact]
    public void ObjectsAreNotMovedPastAMatrixClipOrMarkedContent()
    {
        foreach (string between in new[] { "1 0 0 1 100 100 cm", "0 0 20 20 re W n", "0 1 0 rg", "/GS0 gs", "EMC" })
        {
            string content = (between == "EMC" ? "/OC /MC0 BDC " : "") + "q 1 0 0 rg 0 0 50 50 re f Q " + between + " q 0 0 1 rg 0 0 50 50 re f Q";
            var session = EditKit.Session(content, more: pdf => pdf.Obj(7, "<</Type /ExtGState /ca 0.5>>"), resources: "/Font <</F1 5 0 R>> /ExtGState <</GS0 7 0 R>>");
            var editor = new PageEditor(session, 0);
            var paths = editor.Objects.OfType<PathObject>().ToList();
            Assert.Equal(2, paths.Count);
            var result = editor.Order(paths[1], OrderMove.Backward);
            Assert.False(result.Done, between);
            Assert.Equal(content, EditKit.Latin(session));
        }
    }

    [Fact]
    public void ObjectsAreStillMovedPastWhollyEnclosedSiblings()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q q 1 0 0 1 100 100 cm 0 1 0 rg 0 0 50 50 re f Q q 0 0 1 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0);
        var paths = editor.Objects.OfType<PathObject>().ToList();
        Assert.True(editor.Order(paths[2], OrderMove.Backward).Done);
        var drawn = EditPaint.Paths(session);
        Assert.Equal(new RgbColor(0, 0, 255), drawn[1].Fill);
    }

    [Fact]
    public void SpacingSetByTheQuoteOperatorAloneDoesNotReachAddedText()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td 5 2 (Hello) \" ET");
        var editor = new PageEditor(session, 0, new EditArialSource());
        Assert.True(editor.AddTextBox(new PdfRect(100, 300, 300, 400), "new text").Done);
        Assert.All(Of(Read(session), "new"), g =>
        {
            Assert.Equal(0, g.Tc);
            Assert.Equal(0, g.Tw);
        });
    }
}
