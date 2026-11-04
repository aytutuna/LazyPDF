using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class TextTestPdf
{
    /// <summary>A Type 1 font that is half an em wide everywhere, so glyph positions are easy to work out.</summary>
    public static void Font(TestPdf pdf, int number, params (int Code, string Text)[] map)
    {
        var widths = string.Join(" ", Enumerable.Repeat("500", 256));
        pdf.Obj(number, $"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 0 /LastChar 255 /Widths [{widths}] /ToUnicode {number + 1} 0 R>>");
        var cmap = new StringBuilder("/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange ");
        var all = map.ToDictionary(m => m.Code, m => m.Text);
        for (int c = 32; c < 127; c++) all.TryAdd(c, ((char)c).ToString());
        cmap.Append(all.Count).Append(" beginbfchar ");
        foreach (var (code, text) in all) cmap.Append($"<{code:X2}> <{string.Concat(text.Select(ch => ((int)ch).ToString("X4")))}> ");
        cmap.Append("endbfchar endcmap");
        pdf.Stream(number + 1, "", cmap.ToString());
    }

    /// <summary>One page of 600 by 800 points whose font /F1 is <see cref="Font"/> (object 5).</summary>
    public static PdfDocument Page(string content, string pageEntries = "", params (int Code, string Text)[] map) =>
        Page(content, "/Font <</F1 5 0 R>>", pageEntries, pdf => Font(pdf, 5, map));

    public static PdfDocument Page(string content, string resources, string pageEntries, Action<TestPdf> objects)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>> {pageEntries}>>");
        pdf.Stream(4, "", content);
        objects(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    public static TextPage Text(string content, string pageEntries = "", params (int Code, string Text)[] map)
    {
        var document = Page(content, pageEntries, map);
        return TextPage.Create(document, document.Pages[0]);
    }

    /// <summary>A line at the given point in /F1 at size 10 unless told otherwise: every glyph is half the size wide.</summary>
    public static string Line(double x, double y, string text, double size = 10) =>
        $"BT /F1 {size} Tf {x} {y} Td ({text}) Tj ET\n";
}
