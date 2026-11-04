using LazyPDF.Core;
using Xunit;
using Pig = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

/// <summary>Files and checks shared by the tests that cross module borders.</summary>
internal static class IntegrationFiles
{
    public const string Password = "user";

    private static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)(i * 3)).ToArray();

    /// <summary>
    /// <paramref name="count"/> pages of 400 by 600 showing "Page n" (fonts /F1 and the form font /Helv),
    /// each with a text field "f<c>n</c>" at the bottom; page 1 also has a check box "agree". Top-level
    /// bookmarks go to the pages in <paramref name="bookmarks"/>.
    /// </summary>
    public static byte[] Form(int count, string prefix = "f", int[]? bookmarks = null, string pageExtra = "")
    {
        var pdf = new TestPdf();
        // 1 catalog, 2 tree, 3 font, 4 acroform; pages 10.., contents 100.., fields 200.., outlines 300..
        var fields = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{200 + i} 0 R")) + $" {300 + 99} 0 R";
        string outlines = bookmarks is null ? "" : "/Outlines 300 0 R";
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R {outlines}>>");
        var kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{10 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 400 600]>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(4, $"<</Fields [{fields}] /DA (/Helv 11 Tf 0 g) /DR <</Font <</Helv 3 0 R>>>>>>");
        for (int i = 0; i < count; i++)
        {
            string annots = $"{200 + i} 0 R" + (i == 0 ? $" {300 + 99} 0 R" : "");
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {100 + i} 0 R /Resources <</Font <</F1 3 0 R /Helv 3 0 R>>>> /Annots [{annots}] {pageExtra}>>");
            pdf.Stream(100 + i, "", $"BT /F1 14 Tf 40 500 Td (Page {i + 1} body text) Tj ET");
            pdf.Obj(200 + i, $"<</Type /Annot /Subtype /Widget /FT /Tx /T ({prefix}{i + 1}) /Rect [40 40 240 60] /F 4 /P {10 + i} 0 R /MK <</BC [0]>>>>");
        }
        pdf.Obj(300 + 99, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [40 100 54 114] /F 4 /P 10 0 R /AS /Off /MK <</BC [0] /CA (4)>>>>");
        if (bookmarks is not null)
        {
            pdf.Obj(300, $"<</Type /Outlines /First 301 0 R /Last {300 + bookmarks.Length} 0 R /Count {bookmarks.Length}>>");
            for (int i = 0; i < bookmarks.Length; i++)
            {
                string prev = i > 0 ? $"/Prev {300 + i} 0 R" : "", next = i < bookmarks.Length - 1 ? $"/Next {302 + i} 0 R" : "";
                pdf.Obj(301 + i, $"<</Title (Chapter {i + 1}) /Parent 300 0 R {prev} {next} /Dest [{10 + bookmarks[i]} 0 R /Fit]>>");
            }
        }
        return pdf.Finish();
    }

    public static PdfSecurity Secure(PdfCryptStrength strength) =>
        PdfSecurity.Create(Password, "owner", PdfPermissions.All, strength, FileId, new Random(11));

    public static byte[] Encrypt(byte[] plain, PdfCryptStrength strength, bool objectStreams = false) =>
        PdfDocument.Open(plain).SaveRewrite(new PdfSaveOptions(objectStreams, Secure(strength), FileId));

    /// <summary>Opens with our reader (no repairs) and PdfPig; returns the text of each page.</summary>
    public static List<string> ReadBack(byte[] bytes, string? password = null)
    {
        var document = PdfDocument.Open(bytes, password);
        Assert.Empty(document.Repairs);
        using var pig = Pig.Open(bytes, new UglyToad.PdfPig.ParsingOptions { Passwords = password is null ? [] : [password], UseLenientParsing = false });
        Assert.Equal(document.Pages.Count, pig.NumberOfPages);
        return [.. Enumerable.Range(1, pig.NumberOfPages).Select(i => pig.GetPage(i).Text)];
    }

    public static PdfDocument Reopen(PdfEditSession session, string? password = null)
    {
        var bytes = session.Current.ToArray();
        ReadBack(bytes, password);
        return PdfDocument.Open(bytes, password);
    }
}
