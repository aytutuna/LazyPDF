using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class TextMarkupTests
{
    private static readonly MarkupQuad[] Line = [MarkupQuad.FromRect(new PdfRect(100, 500, 300, 514))];
    private static readonly AnnotationInfo Info = new("Ayşe", "check this", "Review", new DateTimeOffset(2026, 3, 4, 10, 0, 0, TimeSpan.Zero));

    [Fact]
    public void HighlightMultipliesInItsOwnAppearance()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        var highlight = writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line, Info, new AnnotationStyle(Opacity: 0.5));

        Assert.Equal("Highlight", highlight.Subtype);
        Assert.Equal(0.5, highlight.Opacity);
        Assert.Equal([1d, 1d, 0d], highlight.Color);
        var form = Normal(document, highlight);
        Assert.Equal("Form", document.Name(form.Dictionary, "Subtype"));
        var state = document.Dict(document.Dict(document.Dict(form.Dictionary, "Resources"), "ExtGState"), "GS1")!;
        Assert.Equal("Multiply", document.Name(state, "BM"));
        Assert.Equal(0.5, document.Number(state, "ca"));
        var ops = Appearance(document, highlight);
        Assert.Contains("gs", Operators(ops));
        Assert.Contains("f", Operators(ops));
    }

    [Fact]
    public void BoxOfTheAppearanceIsTheRectangle()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        var highlight = writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line);
        var box = AnnotationPoints(document.Array(Normal(document, highlight).Dictionary, "BBox")!);
        Assert.Equal([0, 0, highlight.Rect.Width, highlight.Rect.Height], box);
        Assert.Equal(new PdfRect(99, 499, 301, 515), highlight.Rect);
    }

    private static double[] AnnotationPoints(PdfArray array) => [.. array.Items.Select(i => ((PdfNumber)i).Value)];

    [Theory]
    [InlineData(AnnotationType.Underline, "S")]
    [InlineData(AnnotationType.StrikeOut, "S")]
    [InlineData(AnnotationType.Squiggly, "S")]
    public void LinesAreStrokedInTheAnnotationColour(AnnotationType kind, string painting)
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        var markup = writer.AddTextMarkup(document.Pages[0], kind, [Line[0], MarkupQuad.FromRect(new PdfRect(100, 480, 200, 494))], Info, new AnnotationStyle([0, 0.5, 1]));
        var ops = Appearance(document, markup);
        Assert.Equal(2, ops.Count(o => o.Operator == painting));
        Assert.Contains(ops, o => o.Operator == "RG" && o.Number(2) == 1d);
        Assert.Equal(2, markup.Quads.Count);
    }

    [Fact]
    public void SquigglyZigzagsAlongTheBaseline()
    {
        var document = Blank();
        var squiggly = new PdfAnnotationWriter(document).AddTextMarkup(document.Pages[0], AnnotationType.Squiggly, Line);
        var points = Appearance(document, squiggly).Where(o => o.Operator is "m" or "l").Select(o => o.Number(1)!.Value).ToList();
        Assert.True(points.Count > 50);
        Assert.Equal([1.4, 2.8], points.Take(2).Select(y => Math.Round(y, 1)).ToArray());
    }

    [Fact]
    public void KeepsAuthorDatesAndName()
    {
        var document = Blank();
        var highlight = new PdfAnnotationWriter(document).AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line, Info);
        var reread = PdfAnnotations.Read(Reopen(document), document.Pages[0]).Single();
        Assert.Equal("Ayşe", reread.Title);
        Assert.Equal("check this", reread.Contents);
        Assert.Equal("Review", reread.Subject);
        Assert.Equal(Info.Date, reread.Created);
        Assert.Equal(Info.Date, reread.Modified);
        Assert.False(string.IsNullOrEmpty(reread.Name));
        Assert.Equal(AnnotationFlags.Print, reread.Flags);
        Assert.Equal(highlight.Name, reread.Name);
        Assert.True(reread.HasAppearance);
    }

    [Fact]
    public void PdfPigReadsTheHighlight()
    {
        var document = Blank();
        new PdfAnnotationWriter(document).AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line, Info);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        var annotation = Assert.Single(pig.GetPage(1).GetAnnotations());
        Assert.Equal(UglyToad.PdfPig.Annotations.AnnotationType.Highlight, annotation.Type);
        Assert.Equal("check this", annotation.Content);
    }

    [Fact]
    public void RefusesOtherKindsAndNoQuads()
    {
        var document = Blank();
        var writer = new PdfAnnotationWriter(document);
        Assert.Throws<ArgumentException>(() => writer.AddTextMarkup(document.Pages[0], AnnotationType.Ink, Line));
        Assert.Throws<ArgumentException>(() => writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, []));
    }

    [Fact]
    public void AppendsToAnIndirectAnnotsArray()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "[]"), "/Annots 20 0 R");
        new PdfAnnotationWriter(document).AddTextMarkup(document.Pages[0], AnnotationType.Highlight, Line);
        Assert.Single(((PdfArray)document.Get(20)!).Items);
    }
}
