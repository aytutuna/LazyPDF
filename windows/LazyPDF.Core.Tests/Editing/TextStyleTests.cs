using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TextStyleTests
{
    private const string Line = "BT /F1 12 Tf 50 700 Td (one two three) Tj ET";

    private static List<(string Text, string Font, double Size)> Fonts(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = new List<(string, string, double)>();
        new ContentInterpreter(document).Run(document.Pages[0], new Probe(found));
        return found;
    }

    private sealed class Probe(List<(string, string, double)> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => found.Add((glyph.Unicode ?? "", glyph.Font.Name, context.State.FontSize));
    }

    [Fact]
    public void BoldTakesTheBoldFaceOfTheSameFamilyForTheSelectionOnly()
    {
        var session = EditKit.Session(Line);
        var result = new PageEditor(session, 0, new EditArialSource()).SetTextStyle([EditKit.Find(session, "two")], new TextStyleChange(Bold: true));
        Assert.True(result.Done, result.Problem);
        var fonts = Fonts(session);
        Assert.Equal("one two three", string.Concat(fonts.Select(f => f.Text)));
        Assert.Equal(["Helvetica-Bold"], fonts.Skip(4).Take(3).Select(f => f.Font).Distinct());
        Assert.Equal(["Helvetica"], fonts.Take(4).Concat(fonts.Skip(7)).Select(f => f.Font).Distinct());
    }

    [Fact]
    public void ItalicAndAFamilyChangeWork()
    {
        var session = EditKit.Session(Line);
        var editor = new PageEditor(session, 0, new EditArialSource());
        Assert.True(editor.SetTextStyle([EditKit.Find(session, "one")], new TextStyleChange(Italic: true)).Done);
        Assert.True(new PageEditor(session, 0, new EditArialSource()).SetTextStyle([EditKit.Find(session, "three")], new TextStyleChange(Family: "Times New Roman")).Done);
        var fonts = Fonts(session);
        Assert.Equal("Helvetica-Oblique", fonts[0].Font);
        Assert.Equal("Times-Roman", fonts[^1].Font);
        Assert.Equal("Helvetica", fonts[4].Font);
        Assert.Equal("one two three", string.Concat(fonts.Select(f => f.Text)));
    }

    [Fact]
    public void AFamilyWithTurkishLettersIsEmbedded()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (kagit ve canta) Tj ET");
        Assert.True(new PageEditor(session, 0, new EditArialSource()).ReplaceText(EditKit.Find(session, "kagit"), "kağıt").Done);
        var result = new PageEditor(session, 0, new EditArialSource()).SetTextStyle([EditKit.Find(session, "kağıt")], new TextStyleChange(Family: "Verdana", Bold: true));
        Assert.True(result.Done, result.Problem);
        Assert.Contains("kağıt ve", EditKit.Text(session));
        Assert.Contains("kağıt", EditKit.Pig(session));
    }

    [Fact]
    public void SizeChangesTheSelectionAndOneUndoStepBringsItBack()
    {
        var session = EditKit.Session(Line);
        Assert.True(new PageEditor(session, 0).SetTextStyle([EditKit.Find(session, "two")], new TextStyleChange(Size: 24)).Done);
        var fonts = Fonts(session);
        Assert.Equal([12, 24, 12], new[] { fonts[0].Size, fonts[5].Size, fonts[10].Size });
        Assert.Equal("Format text", session.UndoLabel);
        session.Undo();
        Assert.All(Fonts(session), f => Assert.Equal(12, f.Size));
    }

    [Fact]
    public void ASelectionOverTwoLinesIsStyledOnBoth()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (first line) Tj 0 -14 Td (second line) Tj ET");
        var editor = new PageEditor(session, 0);
        var range = new TextRange(0, editor.Text.Chars.Count);
        Assert.True(editor.SetTextStyle([range], new TextStyleChange(Color: new RgbColor(0, 0, 255))).Done);
        var document = PdfDocument.Open(session.Current.ToArray());
        var colors = new List<RgbColor>();
        new ContentInterpreter(document).Run(document.Pages[0], new ColorProbe(colors));
        Assert.All(colors, c => Assert.Equal(new RgbColor(0, 0, 255), c));
    }

    private sealed class ColorProbe(List<RgbColor> colors) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => colors.Add(context.State.FillColor.Rgb);
    }
}
