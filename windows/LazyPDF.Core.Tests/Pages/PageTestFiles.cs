using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;
using Pig = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

/// <summary>Small files for the page tests: page <c>i</c> shows "Page i+1", and every page has the same font.</summary>
internal static class PageTestFiles
{
    public const int Font = 3;

    public static int PageObject(int index) => 4 + index;

    /// <summary>The first object number the extras may use.</summary>
    public static int Free(int count) => 4 + 2 * count;

    /// <summary>
    /// Catalog 1, tree 2 (flat, with <paramref name="rootExtra"/>), font 3, pages 4... and their
    /// contents after them. <paramref name="pageExtra"/> adds entries to a page dictionary,
    /// <paramref name="add"/> adds objects from <see cref="Free"/> on.
    /// </summary>
    public static byte[] Make(int count, string catalogExtra = "", Func<int, string>? pageExtra = null, string rootExtra = "", Action<TestPdf>? add = null, string trailerExtra = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogExtra}>>");
        var kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{PageObject(i)} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 200 300] {rootExtra}>>");
        pdf.Obj(Font, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        for (int i = 0; i < count; i++)
        {
            pdf.Obj(PageObject(i), $"<</Type /Page /Parent 2 0 R /Contents {4 + count + i} 0 R /Resources <</Font <</F1 {Font} 0 R>>>> {pageExtra?.Invoke(i)}>>");
        }
        for (int i = 0; i < count; i++) pdf.Stream(4 + count + i, "", $"BT /F1 12 Tf 20 100 Td (Page {i + 1}) Tj ET");
        add?.Invoke(pdf);
        return pdf.Finish("/Root 1 0 R " + trailerExtra);
    }

    public static PdfDocument Open(int count, string catalogExtra = "", Func<int, string>? pageExtra = null, string rootExtra = "", Action<TestPdf>? add = null) =>
        PdfDocument.Open(Make(count, catalogExtra, pageExtra, rootExtra, add));

    /// <summary>The "Page n" numbers the pages show, in order.</summary>
    public static List<int> Order(PdfDocument document) =>
        [.. document.Pages.Select(p => int.Parse(Regex.Match(Encoding.Latin1.GetString(p.Contents()), @"\(Page (\d+)\)").Groups[1].Value))];

    /// <summary>Saves by rewrite and reads the result with our reader (no repairs) and with PdfPig; returns the text of each page.</summary>
    public static List<string> Reopen(PdfDocument document)
    {
        byte[] bytes = document.SaveRewrite();
        var again = PdfDocument.Open(bytes);
        Assert.Empty(again.Repairs);
        using var pig = Pig.Open(bytes);
        Assert.Equal(again.Pages.Count, pig.NumberOfPages);
        return [.. Enumerable.Range(1, pig.NumberOfPages).Select(i => pig.GetPage(i).Text)];
    }

    /// <summary>Commits through a session, reopens the committed bytes and returns that document.</summary>
    public static PdfDocument Commit(PdfEditSession session, string label = "edit")
    {
        Assert.True(session.Commit(label));
        var document = PdfDocument.Open(session.Current.ToArray());
        Assert.Empty(document.Repairs);
        return document;
    }
}
