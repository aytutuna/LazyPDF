using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Returns the same words for every page, or what <paramref name="words"/> says for the page's call number.</summary>
internal sealed class FakeRecognizer(Func<int, IReadOnlyList<OcrWord>> words) : ITextRecognizer
{
    public FakeRecognizer(IReadOnlyList<OcrWord> same) : this(_ => same)
    {
    }

    public List<(int Width, int Height, string Language)> Calls { get; } = [];

    public Func<int, Task>? Before { get; init; }

    public async Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
    {
        Calls.Add((image.Width, image.Height, language));
        if (Before is not null) await Before(Calls.Count - 1);
        return words(Calls.Count - 1);
    }
}

/// <summary>Draws blank pictures of the right size for the page as shown, none over 2000 pixels on a side.</summary>
internal sealed class FakeRenderer(PdfDocument document, params int[] unrenderable) : IPageRenderer
{
    public List<(int Page, double Dpi)> Calls { get; } = [];

    public PdfRgbaImage? Render(int pageIndex, double dpi)
    {
        Calls.Add((pageIndex, dpi));
        if (unrenderable.Contains(pageIndex)) return null;
        var geometry = new PageGeometry(document.Pages[pageIndex]);
        double scale = Math.Min(dpi / 72, 2000 / Math.Max(geometry.Width, geometry.Height));
        int width = Math.Max(1, (int)Math.Round(geometry.Width * scale)), height = Math.Max(1, (int)Math.Round(geometry.Height * scale));
        return new PdfRgbaImage(width, height, new byte[width * height * 4]);
    }
}

internal static class OcrKit
{
    public const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>";

    /// <summary>
    /// Four words on two lines, in pixels of a picture drawn at <paramref name="dpi"/> of a page shown
    /// 400 points wide: the boxes in points are (40,100,100,24) (160,100,110,24) (40,160,120,24) (180,160,60,24).
    /// </summary>
    public static List<OcrWord> Words(double dpi = 72)
    {
        double k = dpi / 72;
        OcrWord W(string text, double x, double y, double w, double h) => new(text, new OcrBox(x * k, y * k, w * k, h * k), 0.9f);
        return [W("Hello", 40, 100, 100, 24), W("world", 160, 100, 110, 24), W("Second", 40, 160, 120, 24), W("line", 180, 160, 60, 24)];
    }

    public static readonly (string Text, double X, double Y, double Width, double Height)[] WordBoxes =
        [("Hello", 40, 100, 100, 24), ("world", 160, 100, 110, 24), ("Second", 40, 160, 120, 24), ("line", 180, 160, 60, 24)];

    /// <summary>
    /// A document of <paramref name="count"/> pages, 400 by 600 points. Each draws <paramref name="content"/>
    /// (a full-page picture by default) and has the picture as /Im1 and Helvetica as /F1;
    /// <paramref name="pageEntries"/> goes into every page.
    /// </summary>
    public static byte[] ScanBytes(int count = 1, string pageEntries = "", string content = "q 400 0 0 600 0 0 cm /Im1 Do Q")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        string kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 400 600]>>");
        int image = 3 + 2 * count;
        for (int i = 0; i < count; i++)
        {
            pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + count + i} 0 R /Resources <</XObject <</Im1 {image} 0 R>> /Font <</F1 {image + 1} 0 R>>>> {pageEntries}>>");
        }
        for (int i = 0; i < count; i++) pdf.Stream(3 + count + i, "", content);
        pdf.Stream(image, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0x20, 0x80, 0xC0, 0xF0]);
        pdf.Obj(image + 1, Helvetica);
        return pdf.Finish();
    }

    public static PdfDocument Scan(int count = 1, string pageEntries = "", string content = "q 400 0 0 600 0 0 cm /Im1 Do Q") =>
        PdfDocument.Open(ScanBytes(count, pageEntries, content));

    /// <summary>Pages whose content is given, 400 by 600, with Helvetica as /F1.</summary>
    public static PdfDocument Pages(params string[] contents)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        string kids = string.Join(" ", contents.Select((_, i) => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {contents.Length} /MediaBox [0 0 400 600]>>");
        int font = 3 + 2 * contents.Length;
        for (int i = 0; i < contents.Length; i++)
        {
            pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + contents.Length + i} 0 R /Resources <</Font <</F1 {font} 0 R>>>>>>");
        }
        for (int i = 0; i < contents.Length; i++) pdf.Stream(3 + contents.Length + i, "", contents[i]);
        pdf.Obj(font, Helvetica);
        return PdfDocument.Open(pdf.Finish());
    }

    public static OcrWord Word(string text, double x, double y, double w, double h) => new(text, new OcrBox(x, y, w, h));

    /// <summary>The words of the page and where they sit on the page as shown.</summary>
    public static List<(string Text, DisplayRect Box)> Located(PdfDocument document, int pageIndex = 0)
    {
        var page = document.Pages[pageIndex];
        var geometry = new PageGeometry(page);
        return [.. TextPage.Create(document, page).Words.Select(w => (w.Text, geometry.ToDisplay(w.Bounds)))];
    }

    public static void AssertAtBoxes(PdfDocument document, int pageIndex = 0)
    {
        var found = Located(document, pageIndex);
        Assert.Equal(WordBoxes.Select(b => b.Text), found.Select(f => f.Text));
        for (int i = 0; i < WordBoxes.Length; i++)
        {
            var (_, x, y, w, h) = WordBoxes[i];
            var box = found[i].Box;
            Assert.True(Math.Abs(box.X - x) < 1 && Math.Abs(box.Y - y) < 1 && Math.Abs(box.Width - w) < 1 && Math.Abs(box.Height - h) < 1,
                        $"{found[i].Text} is at {box}, wanted ({x}, {y}, {w}, {h})");
        }
    }

    public static string PigText(byte[] file, string? password = null, int page = 1)
    {
        using var pig = password is null ? UglyToad.PdfPig.PdfDocument.Open(file) : UglyToad.PdfPig.PdfDocument.Open(file, new UglyToad.PdfPig.ParsingOptions { Passwords = [password] });
        return pig.GetPage(page).Text;
    }

    public static int LayerStreams(PdfDocument document, int pageIndex = 0)
    {
        var contents = document.Resolve(document.Pages[pageIndex].Dictionary["Contents"]);
        var items = contents is PdfArray array ? array.Items : [document.Pages[pageIndex].Dictionary["Contents"]!];
        return items.Count(i => document.Resolve(i) is PdfStream s && s.Dictionary.ContainsKey("LazyPDFOcr"));
    }

    public static string Latin(byte[] bytes) => Encoding.Latin1.GetString(bytes);
}
