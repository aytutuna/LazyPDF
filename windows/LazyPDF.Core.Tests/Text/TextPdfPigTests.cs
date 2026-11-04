using System.Text;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

// A second reader as a check on what the page engine says is on a page.
public class TextPdfPigTests
{
    [Fact]
    public void WordsAndPlacesAgreeWithPdfPig()
    {
        var sb = new StringBuilder();
        string[] lines = ["Lazy PDF reads text", "in lines and words", "with positions"];
        for (int i = 0; i < lines.Length; i++) sb.Append($"BT /Helv 12 Tf 72 {700 - i * 16} Td ({lines[i]}) Tj ET\n");
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</Helv 5 0 R>>>>>>");
        pdf.Stream(4, "", sb.ToString());
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        var bytes = pdf.Finish();

        using var document = PdfDocument.Open(bytes);
        var page = TextPage.Create(document, document.Pages[0]);
        using var pig = PigDocument.Open(bytes);
        var theirs = pig.GetPage(1).GetWords().ToList();

        Assert.Equal(theirs.Select(w => w.Text), page.Words.Select(w => w.Text));
        for (int i = 0; i < theirs.Count; i++)
        {
            var (ours, box) = (page.Words[i].Bounds, theirs[i].BoundingBox);
            Assert.Equal(box.Left, ours.Left, 0.6);
            Assert.Equal(box.Right, ours.Right, 0.6);
            Assert.InRange(box.Bottom, ours.Bottom - 3, ours.Top);
        }
    }
}
