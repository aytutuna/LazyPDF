using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImposeTests
{
    private static ImposeResult NUp(PdfDocument source, int per, double width = 600, double height = 400, double gap = 0, bool border = false) =>
        PageOperations.Impose(source, [.. Enumerable.Range(0, source.Pages.Count)], new ImposeOptions(ImposeMode.NUp, width, height, per, gap, border));

    private static ImposeResult Booklet(PdfDocument source, double width = 300, double height = 400) =>
        PageOperations.Impose(source, [.. Enumerable.Range(0, source.Pages.Count)], new ImposeOptions(ImposeMode.Booklet, width, height));

    // What a sheet draws: the "Page n" its form shows (0 when none) and where the form's box lands.
    private static List<(int Page, PdfRect Box, PdfMatrix Matrix)> Placed(PdfDocument document, int sheet)
    {
        var page = document.Pages[sheet];
        var forms = document.Dict(page.Resources, "XObject")!;
        var found = new List<(int, PdfRect, PdfMatrix)>();
        PdfMatrix current = PdfMatrix.Identity;
        foreach (var op in ContentParser.Parse(page.Contents()))
        {
            if (op.Operator == "cm")
            {
                var n = op.Operands.Select(o => ((PdfNumber)o).Value).ToArray();
                current = new PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5]);
            }
            else if (op.Operator == "Do")
            {
                var form = (PdfStream)document.Resolve(forms[((PdfName)op.Operands[0]).Value])!;
                var match = Regex.Match(Encoding.Latin1.GetString(document.Data(form)), @"\(Page (\d+)\)");
                found.Add((match.Success ? int.Parse(match.Groups[1].Value) : 0, current.Transform(document.Rect(form.Dictionary, "BBox")!.Value), current));
            }
        }
        return found;
    }

    private static string Sheets(PdfDocument document) =>
        string.Join(" | ", Enumerable.Range(0, document.Pages.Count).Select(i => string.Join(",", Placed(document, i).Select(p => p.Page))));

    [Fact]
    public void FourUpFillsAcrossThenDown()
    {
        var result = NUp(PageTestFiles.Open(5), 4);
        Assert.Equal(2, result.Sheets);
        var document = result.Document;
        Assert.Equal("1,2,3,4 | 5", Sheets(document));
        Assert.Equal(new PdfRect(0, 0, 600, 400), document.Pages[0].MediaBox);
        var cells = Placed(document, 0);
        // Pages of 200x300 fit a 300x200 cell at two thirds.
        double fit = 200.0 / 300;
        Assert.Equal(200 * fit, cells[0].Box.Width, 3);
        Assert.True(cells[1].Box.Left > cells[0].Box.Left && cells[1].Box.Bottom == cells[0].Box.Bottom);
        Assert.True(cells[2].Box.Bottom < cells[0].Box.Bottom && cells[2].Box.Left == cells[0].Box.Left);
        Assert.Equal(cells[3].Box.Left, cells[1].Box.Left, 3);
        Assert.Equal(cells[3].Box.Bottom, cells[2].Box.Bottom, 3);
        // Page 5 is alone and sits in the first cell.
        Assert.Equal(cells[0].Box.Left, Placed(document, 1)[0].Box.Left, 3);
    }

    [Theory]
    [InlineData(2, 1)]
    [InlineData(6, 1)]
    [InlineData(9, 1)]
    [InlineData(16, 1)]
    public void EverySupportedCountMakesTheRightNumberOfSheets(int per, int expected)
    {
        var result = NUp(PageTestFiles.Open(per), per);
        Assert.Equal(expected, result.Sheets);
        Assert.Equal(per, Placed(result.Document, 0).Count);
        var reopened = PageTestFiles.Reopen(result.Document);
        Assert.Contains($"Page {per}", reopened[0]);
    }

    [Fact]
    public void GapAndBorderAreDrawn()
    {
        var result = NUp(PageTestFiles.Open(2), 2, width: 400, height: 300, gap: 10, border: true);
        var cells = Placed(result.Document, 0);
        double a = cells[0].Box.Right, b = cells[1].Box.Left;
        Assert.True(b - a >= 10 - 1e-6);
        Assert.True(cells[0].Box.Left >= 10 - 1e-6);
        Assert.Contains(" re", Encoding.Latin1.GetString(result.Document.Pages[0].Contents()));
        Assert.Throws<ArgumentOutOfRangeException>(() => NUp(PageTestFiles.Open(2), 2, width: 400, height: 300, gap: 200));
    }

    [Fact]
    public void BookletOrdersPagesForFolding()
    {
        var result = Booklet(PageTestFiles.Open(8));
        Assert.Equal(4, result.Sheets);
        Assert.Equal("8,1 | 2,7 | 6,3 | 4,5", Sheets(result.Document));
        // Landscape whatever the orientation given.
        Assert.Equal(new PdfRect(0, 0, 400, 300), result.Document.Pages[0].MediaBox);
    }

    [Fact]
    public void BookletPadsWithBlanksToAMultipleOfFour()
    {
        var result = Booklet(PageTestFiles.Open(5));
        Assert.Equal(4, result.Sheets);
        Assert.Equal("1 | 2 | 3 | 4,5", Sheets(result.Document));
        // The right-hand cell is empty on the back of the first leaf, the left one on its front.
        Assert.True(Placed(result.Document, 0)[0].Box.Left > 100);
        Assert.True(Placed(result.Document, 1)[0].Box.Left < 100);
        Assert.Equal(2, Booklet(PageTestFiles.Open(1)).Sheets);
    }

    [Fact]
    public void TheSourceIsLeftAlone()
    {
        var document = PageTestFiles.Open(3);
        NUp(document, 2);
        Assert.Equal([1, 2, 3], PageTestFiles.Order(document));
        Assert.Empty(PdfDocument.Open(document.SaveRewrite()).Repairs);
    }

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void RotationAndCropBoxAreKept(int turn)
    {
        var document = PageTestFiles.Open(1, pageExtra: _ => $"/Rotate {turn} /CropBox [20 30 120 230]");
        var result = PageOperations.Impose(document, [0], new ImposeOptions(ImposeMode.NUp, 400, 400, 2));
        var (_, box, matrix) = Placed(result.Document, 0)[0];
        bool sideways = turn != 180;
        // The crop box is 100x200, shown 200x100 when sideways; the 200x400 cell scales it by 1 or 2.
        Assert.Equal(200, box.Width, 3);
        Assert.Equal(sideways ? 100 : 400, box.Height, 3);
        var lowerLeft = matrix.Transform(20, 30);
        var upperRight = matrix.Transform(120, 230);
        switch (turn)
        {
            case 90:
                Assert.Equal(box.Left, lowerLeft.X, 3);
                Assert.Equal(box.Top, lowerLeft.Y, 3);
                break;
            case 180:
                Assert.Equal(box.Right, lowerLeft.X, 3);
                Assert.Equal(box.Top, lowerLeft.Y, 3);
                break;
            default:
                Assert.Equal(box.Right, lowerLeft.X, 3);
                Assert.Equal(box.Bottom, lowerLeft.Y, 3);
                break;
        }
        Assert.Equal(box.Right + box.Left - lowerLeft.X, upperRight.X, 3);
        Assert.Equal(box.Top + box.Bottom - lowerLeft.Y, upperRight.Y, 3);
    }

    [Fact]
    public void AnnotationsWithAnAppearanceAreFlattenedAndTheRestDropped()
    {
        int free = PageTestFiles.Free(1);
        var bytes = PageTestFiles.Make(1,
            pageExtra: _ => $"/Annots [{free} 0 R {free + 1} 0 R {free + 2} 0 R]",
            add: pdf =>
            {
                pdf.Obj(free, $"<</Type /Annot /Subtype /Square /Rect [10 10 60 60] /F 4 /AP <</N {free + 3} 0 R>>>>");
                pdf.Obj(free + 1, "<</Type /Annot /Subtype /Link /Rect [0 0 20 20] /Border [0 0 0]>>");
                pdf.Obj(free + 2, "<</Type /Annot /Subtype /Text /Rect [70 70 90 90] /Contents (note)>>");
                pdf.Stream(free + 3, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "1 0 0 rg 0 0 50 50 re f");
            });
        var result = PageOperations.Impose(PdfDocument.Open(bytes), [0], new ImposeOptions(ImposeMode.NUp, 400, 300, 2));
        Assert.Equal(1, result.AnnotationsFlattened);
        Assert.Equal(2, result.AnnotationsDropped);
        var document = PdfDocument.Open(result.Document.SaveRewrite());
        Assert.Empty(document.Repairs);
        Assert.Null(document.Pages[0].Dictionary["Annots"]);
        var forms = document.Dict(document.Pages[0].Resources, "XObject")!;
        var form = (PdfStream)document.Resolve(forms.Entries.First().Value)!;
        Assert.Contains(" Do", Encoding.Latin1.GetString(document.Data(form)));
    }

    [Fact]
    public void FormFieldsAreNotCarriedOver()
    {
        int free = PageTestFiles.Free(1);
        var bytes = PageTestFiles.Make(1, $"/AcroForm <</Fields [{free} 0 R {free + 1} 0 R] /NeedAppearances true>>",
            pageExtra: _ => $"/Annots [{free} 0 R {free + 1} 0 R]",
            add: pdf =>
            {
                pdf.Obj(free, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /V (x) /Rect [10 10 60 60] /F 4 /AP <</N {free + 2} 0 R>>>>");
                pdf.Obj(free + 1, "<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [70 70 90 90]>>");
                pdf.Stream(free + 2, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "0 0 1 rg 0 0 50 50 re f");
            });
        var result = PageOperations.Impose(PdfDocument.Open(bytes), [0], new ImposeOptions(ImposeMode.NUp, 400, 300, 2));
        Assert.Equal(1, result.AnnotationsFlattened);
        Assert.Equal(1, result.AnnotationsDropped);
        Assert.Null(result.Document.Catalog["AcroForm"]);
        var document = PdfDocument.Open(result.Document.SaveRewrite());
        Assert.Null(document.Catalog["AcroForm"]);
    }

    [Fact]
    public void BadArgumentsAreRefused()
    {
        var document = PageTestFiles.Open(2);
        Assert.Throws<ArgumentException>(() => PageOperations.Impose(document, [], new ImposeOptions(ImposeMode.NUp, 400, 300)));
        Assert.Throws<ArgumentException>(() => NUp(document, 3));
        Assert.Throws<ArgumentOutOfRangeException>(() => NUp(document, 2, width: 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.Impose(document, [2], new ImposeOptions(ImposeMode.NUp, 400, 300)));
    }
}
