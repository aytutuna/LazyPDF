using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

internal static class AnnotationFixtures
{
    /// <summary>Pages are 3 and up, 600 by 800 points with no content; <paramref name="more"/> adds objects from number 20.</summary>
    public static PdfDocument Blank(int pages = 2, Action<TestPdf>? more = null, string pageEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages} /MediaBox [0 0 600 800]>>");
        for (int i = 0; i < pages; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R {pageEntries}>>");
        more?.Invoke(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    /// <summary>
    /// The document written both ways and read again, PdfPig opening each; the document read from the
    /// update is returned.
    /// </summary>
    public static PdfDocument Reopen(PdfDocument document)
    {
        var rewritten = document.SaveRewrite();
        using (var pig = UglyToad.PdfPig.PdfDocument.Open(rewritten)) Assert.Equal(document.Pages.Count, pig.NumberOfPages);
        Assert.Empty(PdfDocument.Open(rewritten).Repairs);

        var updated = document.SaveIncremental();
        using (var pig = UglyToad.PdfPig.PdfDocument.Open(updated)) Assert.Equal(document.Pages.Count, pig.NumberOfPages);
        var reopened = PdfDocument.Open(updated);
        Assert.Empty(reopened.Repairs);
        return reopened;
    }

    /// <summary>The operators of an annotation's normal appearance, in order.</summary>
    public static IReadOnlyList<ContentOperation> Appearance(PdfDocument document, PdfAnnotation annotation) =>
        ContentParser.Parse(document.Data(Normal(document, annotation)));

    public static PdfStream Normal(PdfDocument document, PdfAnnotation annotation) =>
        document.Stream(document.Dict(annotation.Dictionary, "AP"), "N") ?? throw new Xunit.Sdk.XunitException("The annotation has no /AP /N.");

    public static string[] Operators(IReadOnlyList<ContentOperation> operations) => [.. operations.Select(o => o.Operator)];

    public static bool Has(IReadOnlyList<ContentOperation> operations, string op) => operations.Any(o => o.Operator == op);

    public sealed class ArialSource : IFontSource
    {
        public FontFile? Find(string family, FontStyles style)
        {
            string name = (style.HasFlag(FontStyles.Bold), style.HasFlag(FontStyles.Italic)) switch
            {
                (true, true) => "arialbi.ttf",
                (true, false) => "arialbd.ttf",
                (false, true) => "ariali.ttf",
                _ => "arial.ttf",
            };
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), name);
            Assert.True(File.Exists(path), $"{name} is not installed; these tests need it");
            return new FontFile(File.ReadAllBytes(path));
        }
    }
}
