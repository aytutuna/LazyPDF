using System.Text;
using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

/// <summary>A glyph a stamp drew, placed on the page as shown: the origin in display points (y down) and the direction the text runs in.</summary>
internal sealed record StampGlyph(string Text, double X, double Y, double DirX, double DirY, double Size, double Alpha);

internal sealed class ArialSource : IFontSource
{
    public FontFile? Find(string family, FontStyles style)
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        return new FontFile(File.ReadAllBytes(path));
    }
}

internal static class StampKit
{
    /// <summary>An 8 by 6 pixel colour JPEG.</summary>
    public const string SampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z";

    /// <summary>A document of <paramref name="count"/> pages 200 by 300 points, each with a little text of its own.</summary>
    public static PdfDocument Doc(int count = 3) =>
        Pages([.. Enumerable.Range(1, count).Select(i => ("", $"BT /F1 12 Tf 50 50 Td ({i}) Tj ET"))]);

    /// <summary>One page per entry: the page's extra keys and its content. All have Helvetica as /F1 unless their keys give /Resources.</summary>
    public static PdfDocument Pages(params (string Keys, string Content)[] pages)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", pages.Select((_, i) => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {pages.Length} /MediaBox [0 0 200 300]>>");
        int font = 3 + 2 * pages.Length;
        for (int i = 0; i < pages.Length; i++)
        {
            string resources = pages[i].Keys.Contains("/Resources") ? "" : $"/Resources <</Font <</F1 {font} 0 R>>>>";
            pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + pages.Length + i} 0 R {resources} {pages[i].Keys}>>");
        }
        for (int i = 0; i < pages.Length; i++) pdf.Stream(3 + pages.Length + i, "", pages[i].Content);
        pdf.Obj(font, ContentTestPdf.Helvetica);
        return PdfDocument.Open(pdf.Finish());
    }

    public static byte[] Rewrite(PdfDocument document) => document.SaveRewrite();

    public static string PigText(byte[] file, int page = 1)
    {
        using var pig = PigDocument.Open(file);
        return pig.GetPage(page).Text;
    }

    public static List<StampGlyph> Glyphs(PdfDocument document, int pageIndex)
    {
        var page = document.Pages[pageIndex];
        var geometry = new PageGeometry(page);
        var found = new List<StampGlyph>();
        new ContentInterpreter(document).Run(page, new Collector(geometry, found));
        return found;
    }

    public static string Text(IEnumerable<StampGlyph> glyphs) => string.Concat(glyphs.Select(g => g.Text));

    private sealed class Collector(PageGeometry geometry, List<StampGlyph> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (!context.Marked.Any(m => m.Tag == "Artifact")) return;
            var m = glyph.Matrix;
            var (x, y) = geometry.ToDisplay(m.E, m.F);
            var (x2, y2) = geometry.ToDisplay(m.E + m.A, m.F + m.B);
            double length = Math.Sqrt(Math.Pow(x2 - x, 2) + Math.Pow(y2 - y, 2));
            found.Add(new StampGlyph(glyph.Unicode ?? "", x, y, (x2 - x) / length, (y2 - y) / length, length, context.State.FillAlpha));
        }
    }

    public static IReadOnlyList<PdfDictionary> ContentStreams(PdfDocument document, int pageIndex)
    {
        var contents = document.Resolve(document.Pages[pageIndex].Dictionary["Contents"]);
        var items = contents is PdfArray array ? array.Items : [document.Pages[pageIndex].Dictionary["Contents"]!];
        return [.. items.Select(i => ((PdfStream)document.Resolve(i)!).Dictionary)];
    }

    public static string Latin(PdfDocument document, int pageIndex) => Encoding.Latin1.GetString(document.Pages[pageIndex].Contents());
}
