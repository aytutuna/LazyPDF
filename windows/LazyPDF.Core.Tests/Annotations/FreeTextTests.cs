using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FreeTextTests
{
    private const string Turkish = "Çok güzel şiir: ığüşöç İĞÜŞÖÇ";

    private static (PdfDocument Document, PdfAnnotationWriter Writer, PdfPage Page) Start(IFontSource? fonts = null)
    {
        var document = Blank();
        return (document, new PdfAnnotationWriter(document, fonts), document.Pages[0]);
    }

    private static Recorder Draw(PdfDocument document, PdfAnnotation annotation)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(Normal(document, annotation), recorder);
        return recorder;
    }

    private static List<PdfDictionary> Fonts(PdfDocument document, PdfAnnotation annotation) =>
        [.. document.Dict(document.Dict(Normal(document, annotation).Dictionary, "Resources"), "Font")!.Entries.Select(e => (PdfDictionary)document.Resolve(e.Value)!)];

    [Fact]
    public void EnglishTextUsesAStandardFontWithoutASource()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "Hello, World (café)", info: new AnnotationInfo("Ayşe"));
        var recorder = Draw(document, box);
        Assert.Equal("Hello, World (café)", recorder.Text);
        var font = Assert.Single(Fonts(document, box));
        Assert.Equal("Type1", document.Name(font, "Subtype"));
        Assert.Equal("Hello, World (café)", box.Contents);
        Assert.Equal("FreeText", document.Name(box.Dictionary, "IT"));
    }

    [Fact]
    public void TurkishTextEmbedsAFontFromTheSource()
    {
        var (document, writer, page) = Start(new ArialSource());
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 500, 640), Turkish, new FreeTextStyle("Arial", 14));
        Assert.Equal(Turkish, Draw(document, box).Text);
        var font = Assert.Single(Fonts(document, box));
        Assert.Equal("Type0", document.Name(font, "Subtype"));
        Assert.Equal(Turkish, box.Contents);
        Reopen(document);
    }

    [Fact]
    public void TurkishTextWithoutAFontSourceSaysSo()
    {
        var (_, writer, page) = Start();
        var error = Assert.Throws<InvalidOperationException>(() => writer.AddFreeText(page, new PdfRect(100, 600, 500, 640), Turkish));
        Assert.Equal(AnnotationText.NoFont, error.Message);
    }

    [Fact]
    public void TextWrapsAtTheWidthOfTheBox()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 500, 220, 600), "The quick brown fox jumps over the lazy dog and keeps running", new FreeTextStyle(Size: 12));
        var glyphs = Draw(document, box).Glyphs;
        var lines = glyphs.Select(g => Math.Round(g.Bounds.Bottom, 1)).Distinct().ToList();
        Assert.True(lines.Count >= 4, $"{lines.Count} lines");
        Assert.All(glyphs, g => Assert.True(g.Bounds.Right <= 120 - 2 + 0.01, "a glyph runs out of the box"));
        Assert.Equal("Thequickbrownfoxjumpsoverthelazydogandkeepsrunning", string.Concat(glyphs.Select(g => g.Unicode)).Replace(" ", ""));
    }

    [Fact]
    public void LongWordsBreakAtTheCharacterAndNewlinesStay()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 500, 160, 700), "Supercalifragilisticexpialidocious\nnext");
        var glyphs = Draw(document, box).Glyphs;
        Assert.All(glyphs, g => Assert.True(g.Bounds.Right <= 60 - 2 + 0.01));
        Assert.Equal("Supercalifragilisticexpialidociousnext", string.Concat(glyphs.Select(g => g.Unicode)));
        Assert.True(glyphs[^1].Bounds.Bottom < glyphs[0].Bounds.Bottom);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void AlignmentMovesTheLine(int alignment)
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "Hi", new FreeTextStyle(Alignment: alignment));
        var glyphs = Draw(document, box).Glyphs;
        double left = glyphs[0].Bounds.Left, right = glyphs[^1].Bounds.Right;
        switch (alignment)
        {
            case 0: Assert.Equal(2, left, 1); break;
            case 1: Assert.Equal(100, (left + right) / 2, 1); break;
            default: Assert.Equal(198, right, 1); break;
        }
        Assert.Equal(alignment, box.Alignment);
    }

    [Fact]
    public void TextIsClippedToTheBox()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 160, 620), string.Join(' ', Enumerable.Repeat("overflow", 30)));
        var ops = Operators(Appearance(document, box));
        Assert.Contains("W", ops);
        Assert.True(ops.Count(o => o == "Tj") < 30, "lines far below the box are not written");
    }

    [Fact]
    public void BorderAndFillAreDrawnBehindTheText()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "boxed", style: new AnnotationStyle([1, 0, 0], 2, Fill: [1, 1, 0.8]));
        var ops = Operators(Appearance(document, box));
        Assert.True(Array.IndexOf(ops, "f") < Array.IndexOf(ops, "S"));
        Assert.True(Array.IndexOf(ops, "S") < Array.IndexOf(ops, "BT"));
        Assert.Equal([1d, 1d, 0.8], box.InteriorColor);
    }

    [Fact]
    public void CalloutGrowsTheAnnotationAndKeepsTheBoxInRd()
    {
        var (document, writer, page) = Start();
        var text = new PdfRect(300, 600, 400, 640);
        var box = writer.AddFreeText(page, text, "see here", style: new AnnotationStyle([0, 0, 0], 1),
            callout: [(100, 500), (200, 500), (300, 620)]);
        Assert.Equal("FreeTextCallout", box.Intent);
        Assert.Equal(6, box.Callout.Count);
        Assert.Equal(LineEnding.OpenArrow, box.StartEnding);
        Assert.True(box.Rect.Left < 100 && box.Rect.Bottom < 500 && box.Rect.Right >= 400 && box.Rect.Top >= 640);
        Assert.Equal(4, box.RectDifference.Count);
        Assert.Equal(text.Left, box.Rect.Left + box.RectDifference[0], 3);
        Assert.Equal(text.Top, box.Rect.Top - box.RectDifference[3], 3);
        var recorder = Draw(document, box);
        Assert.Equal("see here", recorder.Text);
        Assert.True(recorder.Paths.Count >= 3, "box border, callout line and arrow");
        Assert.Throws<ArgumentException>(() => writer.AddFreeText(page, text, "x", callout: [(1, 1)]));
    }

    [Fact]
    public void RichTextKeepsBoldAndColour()
    {
        var (document, writer, page) = Start();
        string rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font-size:12pt;font-family:Helvetica\"><p>plain <span style=\"font-weight:bold;color:#FF0000\">loud</span> <i>slanted</i></p><p>second</p></body>";
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 400, 660), "", new FreeTextStyle(RichText: rich));
        Assert.Equal("plain loud slanted\nsecond", box.Contents);
        Assert.Equal(rich, box.RichText);
        var recorder = Draw(document, box);
        Assert.Equal("plain loud slantedsecond", recorder.Text);
        var names = Fonts(document, box).Select(f => document.Name(f, "BaseFont")).ToList();
        Assert.Contains("Helvetica-Bold", names);
        Assert.Contains("Helvetica-Oblique", names);
        Assert.Contains(Appearance(document, box), o => o.Operator == "rg" && o.Number(0) == 1d && o.Number(1) == 0d);
        Assert.Equal(2, recorder.Glyphs.Select(g => Math.Round(g.Bounds.Bottom, 0)).Distinct().Count());
    }

    [Fact]
    public void BrokenRichTextFallsBackToTheContents()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 400, 660), "plain words", new FreeTextStyle(RichText: "<body><p>unclosed"));
        Assert.Equal("plain words", Draw(document, box).Text);
    }

    [Fact]
    public void FontAndColourAreKeptInDaAndDs()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 400, 660), "x", new FreeTextStyle("Times New Roman", 18, FontStyles.Bold | FontStyles.Italic, [0, 0, 1]));
        Assert.Equal("/TiBI 18 Tf 0 0 1 rg", box.DefaultAppearance);
        Assert.Contains("font-family: Times New Roman", box.DefaultStyle);
        Assert.Equal("Times-BoldItalic", document.Name(Fonts(document, box).Single(), "BaseFont"));
        var reread = PdfAnnotations.Read(Reopen(document), document.Pages[0]).Single();
        Assert.Equal(box.DefaultAppearance, reread.DefaultAppearance);
    }

    [Fact]
    public void NoteIconIsDrawnForOtherViewers()
    {
        var (document, writer, page) = Start();
        var note = writer.AddNote(page, new PdfRect(100, 700, 120, 720), new AnnotationInfo("A", "remember"), "Comment");
        Assert.Equal("Comment", note.IconName);
        Assert.True(note.Flags.HasFlag(AnnotationFlags.NoZoom));
        Assert.Contains("B", Operators(Appearance(document, note)));
    }
}
