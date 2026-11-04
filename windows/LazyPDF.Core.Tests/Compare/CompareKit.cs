using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>A line of text on a made page: /F1 Helvetica, /F2 Times-Roman, /F3 Helvetica-Bold.</summary>
internal sealed record CompareLine(string Text, string Font = "F1", double Size = 12, string Color = "0 0 0");

internal sealed class CompareArial : IFontSource
{
    public FontFile? Find(string family, FontStyles style)
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        return new FontFile(File.ReadAllBytes(path));
    }
}

internal static class CompareKit
{
    /// <summary>An 8 by 6 pixel colour JPEG.</summary>
    public const string SampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z";

    public static CompareLine L(string text) => new(text);

    /// <summary>A document with one page for each argument; every page is 612 by 792 with its lines from the top, 20 points apart.</summary>
    public static PdfDocument Doc(params CompareLine[][] pages) => Open(Bytes(pages));

    public static PdfDocument Doc(params string[][] pages) => Doc([.. pages.Select(p => p.Select(L).ToArray())]);

    public static PdfDocument Open(byte[] bytes) => PdfDocument.Open(bytes);

    /// <summary>
    /// The file. Page <c>i</c> is object <c>3 + i</c> with its content after the pages; the three fonts follow.
    /// <paramref name="pageKeys"/> adds keys to every page, <paramref name="more"/> adds objects numbered from <c>FirstFree</c>.
    /// </summary>
    public static byte[] Bytes(CompareLine[][] pages, string pageKeys = "", Func<int, string[]>? pageExtra = null, Action<TestPdf, int>? more = null, string trailer = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", pages.Select((_, i) => $"{3 + i} 0 R"))}] /Count {pages.Length} /MediaBox [0 0 612 792]>>");
        int font = 3 + 2 * pages.Length;
        for (int i = 0; i < pages.Length; i++)
        {
            string extra = pageExtra is null ? "" : string.Join(" ", pageExtra(i));
            pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + pages.Length + i} 0 R /Resources <</Font <</F1 {font} 0 R /F2 {font + 1} 0 R /F3 {font + 2} 0 R>>>> {pageKeys} {extra}>>");
        }
        for (int i = 0; i < pages.Length; i++) pdf.Stream(3 + pages.Length + i, "", Content(pages[i]));
        pdf.Obj(font, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(font + 1, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding>>");
        pdf.Obj(font + 2, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>");
        more?.Invoke(pdf, font + 3);
        return pdf.Finish($"/Root 1 0 R {trailer}");
    }

    public static string Content(CompareLine[] lines)
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            string text = line.Text.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
            sb.Append($"BT /{line.Font} {line.Size} Tf {line.Color} rg 72 {740 - 20 * i} Td ({text}) Tj ET\n");
        }
        return sb.ToString();
    }

    public static ComparisonResult Compare(PdfDocument before, PdfDocument after, CompareOptions? options = null) => PdfComparer.Compare(before, after, options);

    public static ComparisonResult Compare(string[][] before, string[][] after, CompareOptions? options = null)
    {
        using var a = Doc(before);
        using var b = Doc(after);
        return PdfComparer.Compare(a, b, options);
    }

    /// <summary>Lines of ten words each that carry the topic, so that pages with different topics have nothing in common.</summary>
    public static string[] Page(string topic, int lines = 6) =>
        [.. Enumerable.Range(1, lines).Select(i => $"{topic} line{i} " + string.Join(' ', Enumerable.Range(1, 8).Select(k => $"{topic}{i}w{k}")))];
}
