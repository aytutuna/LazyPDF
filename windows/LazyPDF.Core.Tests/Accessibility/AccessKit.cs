using System.Text;
using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

internal static class AccessKit
{
    /// <summary>Object numbers after the pages' own: fonts F1 (Helvetica) and F2 (Helvetica-Bold), a 2 by 2 gray image Im1.</summary>
    public static int FirstFree(int pages) => 6 + 2 * pages;

    /// <summary>
    /// A file of <paramref name="pages"/> pages 612 by 792 whose content is <paramref name="content"/>(i); page i is object 3 + i and
    /// its content stream 3 + pages + i. <paramref name="more"/> adds objects from <see cref="FirstFree"/> on.
    /// </summary>
    public static byte[] Build(int pages, Func<int, string> content, string catalog = "", string pageEntries = "", Action<TestPdf>? more = null, string fontEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages} /MediaBox [0 0 612 792]>>");
        int f1 = 3 + 2 * pages, f2 = f1 + 1, image = f1 + 2;
        for (int i = 0; i < pages; i++)
        {
            pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + pages + i} 0 R /Resources <</Font <</F1 {f1} 0 R /F2 {f2} 0 R {fontEntries}>> /XObject <</Im1 {image} 0 R>>>> {pageEntries}>>");
        }
        for (int i = 0; i < pages; i++) pdf.Stream(3 + pages + i, "", content(i));
        pdf.Obj(f1, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(f2, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>");
        pdf.Stream(image, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 80, 160, 255]);
        more?.Invoke(pdf);
        return pdf.Finish();
    }

    public static string Text(double x, double y, string text, double size = 11, bool bold = false) =>
        $"BT /{(bold ? "F2" : "F1")} {size} Tf {x} {y} Td ({text}) Tj ET\n";

    /// <summary>A page of a report: running header and footer, a rule, a heading, two paragraphs, a bullet list, a table and a picture.</summary>
    public static string ReportPage(int index)
    {
        var s = new StringBuilder();
        s.Append("q 0.8 g 72 745 468 1 re f Q\n");
        s.Append(Text(72, 760, "ACME Quarterly Report", 9));
        s.Append(Text(72, 700, "Introduction", 20, bold: true));
        s.Append($"BT /F1 11 Tf 72 672 Td (This is the first paragraph of page {index + 1}. It has enough words) Tj 0 -14 Td (to fill two lines of the body text.) Tj ET\n");
        s.Append(Text(72, 620, "A second paragraph follows after a clear gap."));
        for (int i = 0; i < 3; i++)
        {
            s.Append($"BT /F1 11 Tf 72 {580 - 16 * i} Td <95> Tj 18 0 Td ({new[] { "First", "Second", "Third" }[i]} item) Tj ET\n");
        }
        string[][] table = [["Name", "Count", "Price"], ["Apples", "12", "3.50"], ["Pears", "7", "4.25"]];
        for (int r = 0; r < table.Length; r++)
        {
            for (int c = 0; c < 3; c++) s.Append(Text(72 + 150 * c, 500 - 16 * r, table[r][c], 11, bold: r == 0));
        }
        s.Append("q 100 0 0 100 72 340 cm /Im1 Do Q\n");
        s.Append(Text(290, 30, $"Page {index + 1}", 9));
        return s.ToString();
    }

    public static byte[] Report(int pages = 3) => Build(pages, ReportPage);

    /// <summary>The words PdfPig reads from page <paramref name="page"/> (1-based), in its order.</summary>
    public static string PigText(byte[] file, int page = 1)
    {
        using var pig = PigDocument.Open(file);
        return string.Join(" ", pig.GetPage(page).GetWords().Select(w => w.Text));
    }

    public static string Plain(PdfDocument document, int page) => TextPage.Create(document, document.Pages[page]).Text;

    /// <summary>The marked-content sequences of a page's content: tag and /MCID (-1 for none), in order, nesting ignored.</summary>
    public static List<(string Tag, int Mcid)> Sequences(PdfDocument document, int page)
    {
        var found = new List<(string, int)>();
        foreach (var op in ContentParser.Parse(document.Pages[page].Contents()))
        {
            if (op.Operator == "BMC" && op.Operands[0] is PdfName a) found.Add((a.Value, -1));
            if (op.Operator == "BDC" && op.Operands[0] is PdfName b)
            {
                int mcid = op.Operands.Count > 1 && op.Operands[1] is PdfDictionary d && d["MCID"] is PdfNumber { Integer: { } n } ? (int)n : -1;
                found.Add((b.Value, mcid));
            }
        }
        return found;
    }

    /// <summary>Balanced BMC/BDC and EMC, in every stream of the page.</summary>
    public static bool IsBalanced(PdfDocument document, int page)
    {
        int depth = 0;
        foreach (var op in ContentParser.Parse(document.Pages[page].Contents()))
        {
            if (op.Operator is "BMC" or "BDC") depth++;
            else if (op.Operator == "EMC" && --depth < 0) return false;
        }
        return depth == 0;
    }

    public static PdfDocument Reopen(PdfDocument document, bool rewrite)
    {
        var bytes = rewrite ? document.SaveRewrite() : document.SaveIncremental();
        using (var pig = PigDocument.Open(bytes)) Assert.True(pig.NumberOfPages >= 0);
        return PdfDocument.Open(bytes);
    }

    public static StructElement? Find(StructureTree tree, string type) => tree.Elements.FirstOrDefault(e => e.Type == type);
}
