using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Small files for the redaction tests: a catalog (1), a page tree (2), Helvetica (5), pages from 30, and whatever the test adds below 30.</summary>
internal static class RedactionFiles
{
    public const string Picture = "q 100 0 0 100 100 100 cm /Im1 Do Q";
    public const string Word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET";
    public static readonly PdfRect Over = new(90, 90, 300, 120);

    public static PdfDocument Open(string content, string resources = "", Action<TestPdf>? more = null, string fonts = "", string pageExtra = "", string catalogExtra = "", string pagesExtra = "") =>
        Open([content], resources, more, fonts, [pageExtra], catalogExtra, pagesExtra);

    public static PdfDocument Open(string[] contents, string resources = "", Action<TestPdf>? more = null, string fonts = "", string[]? pageExtras = null, string catalogExtra = "", string pagesExtra = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", contents.Select((_, i) => $"{30 + 2 * i} 0 R"))}] /Count {contents.Length} /MediaBox [0 0 600 800] {pagesExtra}>>");
        pdf.Obj(5, ContentTestPdf.Helvetica);
        for (int i = 0; i < contents.Length; i++)
        {
            pdf.Obj(30 + 2 * i, $"<</Type /Page /Parent 2 0 R /Contents {31 + 2 * i} 0 R /Resources <</Font <</F1 5 0 R {fonts}>> {resources}>> {pageExtras?[i]}>>");
            pdf.Stream(31 + 2 * i, "", contents[i]);
        }
        more?.Invoke(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    public static void Image(TestPdf pdf, int number, string entries = "", string data = "ZQXPIXELS") =>
        pdf.Stream(number, $"/Type /XObject /Subtype /Image /Width 3 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8 {entries}", data);

    public static RedactionResult Apply(PdfDocument document, params RedactionMark[] marks) => RedactionKit.Apply(document, marks);

    /// <summary>The output passes its own check and holds none of the words.</summary>
    public static void Gone(RedactionResult result, params string[] words)
    {
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        foreach (string word in words) Assert.False(RedactionKit.Holds(result.Bytes, word), word);
    }
}
