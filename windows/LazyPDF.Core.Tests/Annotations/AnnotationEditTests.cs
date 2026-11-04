using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class AnnotationEditTests
{
    private static readonly MarkupQuad[] Line = [MarkupQuad.FromRect(new PdfRect(100, 500, 300, 514))];

    private static (PdfDocument Document, PdfAnnotationWriter Writer, PdfPage Page) Start()
    {
        var document = Blank();
        return (document, new PdfAnnotationWriter(document), document.Pages[0]);
    }

    private static string TextOf(PdfDocument document, PdfAnnotation annotation)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(Normal(document, annotation), recorder);
        return recorder.Text;
    }

    [Fact]
    public void MoveShiftsRectAndEveryPointKey()
    {
        var (document, writer, page) = Start();
        var ink = writer.AddInk(page, [[(100, 600), (120, 640)], [(200, 600), (220, 640)]]);
        var moved = writer.Move(ink, 30, -10);
        Assert.Equal(ink.Rect.Left + 30, moved.Rect.Left);
        Assert.Equal(ink.Rect.Bottom - 10, moved.Rect.Bottom);
        Assert.Equal([130d, 590d, 150d, 630d], moved.InkList[0]);
        var line = writer.Move(writer.AddLine(page, (10, 10), (50, 60)), 5, 5);
        Assert.Equal([15d, 15d, 55d, 65d], line.Line);
        var markup = writer.Move(writer.AddTextMarkup(page, AnnotationType.Highlight, Line), 0, 100);
        Assert.Equal(614d, markup.Quads[0].Y1);
        Assert.Equal(600d, markup.Quads[0].Y3);
        Reopen(document);
    }

    [Fact]
    public void MoveLeavesTheAppearanceStreamAlone()
    {
        var (document, writer, page) = Start();
        var square = writer.AddSquare(page, new PdfRect(100, 600, 200, 650));
        var before = Normal(document, square);
        var moved = writer.Move(square, 40, 40);
        Assert.Same(before, Normal(document, moved));
    }

    [Fact]
    public void ResizeScalesPointsAndDrawsAgain()
    {
        var (document, writer, page) = Start();
        var polygon = writer.AddPolygon(page, [(100, 600), (200, 600), (150, 700)], new AnnotationStyle(Width: 2));
        var before = Normal(document, polygon);
        var bounds = polygon.Rect;
        var target = new PdfRect(bounds.Left, bounds.Bottom, bounds.Left + bounds.Width * 2, bounds.Bottom + bounds.Height / 2);
        var resized = writer.Resize(polygon, target);
        Assert.Equal(target, resized.Rect);
        Assert.Equal(102d, resized.Vertices[0], 3);
        Assert.Equal(302d, resized.Vertices[2], 3);
        Assert.NotSame(before, Normal(document, resized));
        var box = document.Array(Normal(document, resized).Dictionary, "BBox")!;
        Assert.Equal(target.Width, ((PdfNumber)box.Items[2]).Value, 3);
    }

    [Fact]
    public void ResizeRewrapsFreeText()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 500, 400, 600), "one two three four five six seven eight nine ten");
        int Lines(PdfAnnotation a)
        {
            var recorder = new Recorder();
            new ContentInterpreter(document).Run(Normal(document, a), recorder);
            return recorder.Glyphs.Select(g => Math.Round(g.Bounds.Bottom, 1)).Distinct().Count();
        }
        int wide = Lines(box);
        var narrow = writer.Resize(box, new PdfRect(100, 500, 160, 600));
        Assert.True(Lines(narrow) > wide);
    }

    [Fact]
    public void ColourChangeRedrawsTheAppearance()
    {
        var (document, writer, page) = Start();
        var highlight = writer.AddTextMarkup(page, AnnotationType.Highlight, Line);
        var green = writer.SetColor(highlight, [0, 1, 0]);
        Assert.Equal([0d, 1d, 0d], green.Color);
        Assert.Contains(Appearance(document, green), o => o.Operator == "rg" && o.Number(1) == 1d && o.Number(0) == 0d);

        var square = writer.AddSquare(page, new PdfRect(10, 10, 80, 80));
        var filled = writer.SetColor(square, [0, 0, 1], [1, 0, 0]);
        Assert.Equal([1d, 0d, 0d], filled.InteriorColor);
        var painted = Appearance(document, filled);
        Assert.Contains("B", Operators(painted));
        Assert.Contains(painted, o => o.Operator == "RG" && o.Number(2) == 1d);

        var transparent = writer.SetOpacity(green, 0.25);
        Assert.Equal(0.25, transparent.Opacity);
        Assert.Contains("gs", Operators(Appearance(document, transparent)));
    }

    [Fact]
    public void ContentsChangeAndFreeTextIsDrawnAgain()
    {
        var (document, writer, page) = Start();
        var note = writer.AddNote(page, new PdfRect(10, 700, 30, 720), new AnnotationInfo("A", "first"));
        var date = new DateTimeOffset(2026, 5, 6, 7, 8, 9, TimeSpan.Zero);
        var changed = writer.SetContents(note, "second", date);
        Assert.Equal("second", changed.Contents);
        Assert.Equal(date, changed.Modified);

        string rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>old words</p></body>";
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "", new FreeTextStyle(RichText: rich));
        var edited = writer.SetContents(box, "new words");
        Assert.Null(edited.RichText);
        Assert.Equal("new words", TextOf(document, edited));
    }

    [Fact]
    public void FreeTextStyleChangeKeepsTheText()
    {
        var (document, writer, page) = Start();
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "styled");
        var bigger = writer.SetFreeTextStyle(box, new FreeTextStyle("Courier New", 20, FontStyles.Bold, [1, 0, 0], 1));
        Assert.Equal("/CoBo 20 Tf 1 0 0 rg", bigger.DefaultAppearance);
        Assert.Equal(1, bigger.Alignment);
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(Normal(document, bigger), recorder);
        Assert.Equal("styled", recorder.Text);
        Assert.Equal("Courier-Bold", recorder.Glyphs[0].Font.BaseFont);
        Assert.Throws<ArgumentException>(() => writer.SetFreeTextStyle(writer.AddSquare(page, new PdfRect(1, 1, 50, 50)), new FreeTextStyle()));
    }

    [Fact]
    public void DeleteTakesPopupAndRepliesWithIt()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (parent) /Popup 21 0 R /NM (p)>>");
            pdf.Obj(21, "<</Type /Annot /Subtype /Popup /Rect [40 10 140 60] /Parent 20 0 R>>");
            pdf.Obj(22, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 20 0 R /RT /R /Contents (reply)>>");
            pdf.Obj(23, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 22 0 R /Contents (reply to reply)>>");
            pdf.Obj(24, "<</Type /Annot /Subtype /Text /Rect [90 90 100 100] /Contents (other)>>");
        }, "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R]");
        var page = document.Pages[0];
        var writer = new PdfAnnotationWriter(document);
        var parent = PdfAnnotations.Read(document, page)[0];
        Assert.True(writer.Delete(parent));
        Assert.Equal("other", Assert.Single(PdfAnnotations.Read(document, page)).Contents);
        foreach (int number in new[] { 20, 21, 22, 23 }) Assert.Null(document.Get(number));
        Assert.NotNull(document.Get(24));
        Assert.False(writer.Delete(parent));
        Reopen(document);
    }

    [Fact]
    public void DeleteWorksOnAnAnnotationWrittenDirectlyInTheArray()
    {
        var document = Blank(1, pageEntries: "/Annots [<</Subtype /Square /Rect [1 1 20 20]>>]");
        var writer = new PdfAnnotationWriter(document);
        Assert.True(writer.Delete(PdfAnnotations.Read(document, document.Pages[0]).Single()));
        Assert.Empty(PdfAnnotations.Read(document, document.Pages[0]));
    }

    [Fact]
    public void RegenerateGivesAForeignAnnotationAnAppearance()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Square /Rect [100 100 200 150] /C [0 1 0] /BS <</W 3>>>>"), "/Annots [20 0 R]");
        var writer = new PdfAnnotationWriter(document);
        var square = PdfAnnotations.Read(document, document.Pages[0]).Single();
        Assert.False(square.HasAppearance);
        Assert.True(writer.Regenerate(square));
        Assert.True(PdfAnnotations.Read(document, document.Pages[0]).Single().HasAppearance);
        Assert.False(writer.Regenerate(PdfAnnotations.Parse(document, new PdfDictionary { ["Subtype"] = new PdfName("Widget") }, null)!));
    }

    [Fact]
    public void UnknownKeysSurviveEdits()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Square /Rect [100 100 200 150] /C [0 1 0] /Custom (keep) /Foo 42>>"), "/Annots [20 0 R]");
        var writer = new PdfAnnotationWriter(document);
        var square = PdfAnnotations.Read(document, document.Pages[0]).Single();
        writer.SetColor(writer.Move(square, 5, 5), [1, 0, 0]);
        var reopened = Reopen(document);
        var kept = PdfAnnotations.Read(reopened, reopened.Pages[0]).Single();
        Assert.Equal(42, reopened.Integer(kept.Dictionary, "Foo"));
        Assert.True(kept.Dictionary.ContainsKey("Custom"));
    }

    [Fact]
    public void AnEditThatCannotBeDrawnLeavesTheAnnotationAsItWas()
    {
        var document = Blank(1, pdf => pdf.Obj(20,
            "<</Type /Annot /Subtype /FreeText /Rect [100 100 300 150] /C [0 1 0] /Contents <FEFF015F011F> /DA (/Helv 12 Tf 0 g) /Vertices [1 2 3 4] /RC (<body/>)>>"), "/Annots [20 0 R]");
        var writer = new PdfAnnotationWriter(document);
        var box = PdfAnnotations.Read(document, document.Pages[0]).Single();
        Assert.Throws<InvalidOperationException>(() => writer.SetColor(box, [1, 0, 0]));
        Assert.Throws<InvalidOperationException>(() => writer.Resize(box, new PdfRect(0, 0, 500, 500)));
        Assert.Throws<InvalidOperationException>(() => writer.SetContents(box, "ığ"));
        var after = PdfAnnotations.Read(document, document.Pages[0]).Single();
        Assert.Equal([0d, 1d, 0d], after.Color);
        Assert.Equal(box.Rect, after.Rect);
        Assert.Equal([1d, 2d, 3d, 4d], after.Vertices);
        Assert.Equal("<body/>", after.RichText);
        Assert.Equal("şğ", after.Contents);
        Assert.False(after.HasAppearance);
    }
}
