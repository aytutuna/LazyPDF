using System.Text;
using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

/// <summary>A glyph as the content draws it: the text and where its origin is, in user space.</summary>
internal sealed record DrawnGlyph(string Text, double X, double Y);

internal sealed class FakeCodec(PdfRgbaImage? image) : IImageCodec
{
    public PdfRgbaImage? Decode(byte[] data, string codec) => image;
    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => null;
    public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
}

/// <summary>Draws every page as a gradient at the size the page has, so a test can tell where the marks were filled.</summary>
internal sealed class RedactFakeRenderer(PdfDocument document) : IPageRenderer
{
    public List<int> Drawn { get; } = [];
    public List<double> Dpis { get; } = [];

    public PdfRgbaImage? Render(int pageIndex, double dpi)
    {
        Drawn.Add(pageIndex);
        Dpis.Add(dpi);
        var geometry = new PageGeometry(document.Pages[pageIndex]);
        int width = (int)Math.Ceiling(geometry.Width * dpi / 72), height = (int)Math.Ceiling(geometry.Height * dpi / 72);
        var rgba = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = ((byte)(100 + x * 100 / width), (byte)(100 + y * 100 / height), 200, 255);
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }
}

internal static class RedactionKit
{
    /// <summary>The options that let a page the redaction cannot follow become a picture, drawn small to keep the tests quick.</summary>
    public static RedactionOptions Drawing(PdfDocument document, RedactionOptions? options = null) =>
        (options ?? new RedactionOptions()) with { Renderer = new RedactFakeRenderer(document), FlattenDpi = 24 };

    public static RedactionResult Apply(PdfDocument document, IEnumerable<RedactionMark> marks, RedactionOptions? options = null) =>
        new PdfRedactor(document).Apply(marks, Drawing(document, options));

    public static RedactionResult AssertFlattened(PdfDocument document, PdfRect area, params string[] words) =>
        AssertFlattened(document, [RedactionMark.FromRect(0, area)], words);

    /// <summary>
    /// The page of the first mark cannot be followed to its end: the call refuses without a renderer, and with one the page
    /// becomes a picture and none of the words is left in the file.
    /// </summary>
    public static RedactionResult AssertFlattened(PdfDocument document, IReadOnlyList<RedactionMark> marks, params string[] words)
    {
        int page = marks[0].Page;
        var refused = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply(marks));
        Assert.Equal(RedactionText.NeedsPicture(page), refused.Message);
        var result = Apply(document, marks);
        Assert.Contains(page, result.Report.Flattened);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        foreach (string word in words) Assert.False(Holds(result.Bytes, word), word);
        using var output = Reopen(result.Bytes);
        Assert.DoesNotContain("Tj", Latin(output, page));
        Assert.Contains(" Do", Latin(output, page));
        return result;
    }

    public const string Marker = "ZQXMARKER";
    public const string Helvetica = ContentTestPdf.Helvetica;

    /// <summary>A 600 by 800 page with Helvetica as /F1 and the extra resource entries and objects (numbered from 6) given.</summary>
    public static PdfDocument Page(string content, string resources = "", params string[] objects) =>
        ContentTestPdf.Page(content, $"/Font <</F1 5 0 R>> {resources}", [Helvetica, .. objects]);

    public static PdfDocument Page(string content, string resources, Action<TestPdf> more) =>
        ContentTestPdf.Page(content, $"/Font <</F1 5 0 R>> {resources}", pdf =>
        {
            pdf.Obj(5, Helvetica);
            more(pdf);
        });

    public static List<DrawnGlyph> Glyphs(PdfDocument document, int page = 0)
    {
        var found = new List<DrawnGlyph>();
        new ContentInterpreter(document).Run(document.Pages[page], new GlyphCollector(found));
        return found;
    }

    public static string Text(IEnumerable<DrawnGlyph> glyphs) => string.Concat(glyphs.Select(g => g.Text));

    public static string Text(PdfDocument document, int page = 0) => Text(Glyphs(document, page));

    private sealed class GlyphCollector(List<DrawnGlyph> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) =>
            found.Add(new DrawnGlyph(glyph.Unicode ?? "", glyph.Matrix.E, glyph.Matrix.F));
    }

    /// <summary>The mark over a search hit of the page.</summary>
    public static RedactionMark MarkOf(PdfDocument document, int page, string word, double[]? fill = null, string? overlay = null)
    {
        var text = TextPage.Create(document, document.Pages[page]);
        var hit = TextSearch.Find(text, word).FirstOrDefault();
        Assert.True(hit is not null, $"'{word}' is not on page {page}");
        return RedactionMark.FromMatch(hit, fill, overlay);
    }

    public static List<ImageInfo> Images(PdfDocument document, int page = 0)
    {
        var found = new List<ImageInfo>();
        new ContentInterpreter(document).Run(document.Pages[page], new ImageCollector(found));
        return found;
    }

    private sealed class ImageCollector(List<ImageInfo> found) : ContentVisitor
    {
        public override void PaintImage(ContentContext context, ImageInfo image) => found.Add(image);
    }

    public static List<RedactionMark> MarksOf(PdfDocument document, int page, string word)
    {
        var marks = TextSearch.Find(TextPage.Create(document, document.Pages[page]), word).Select(h => RedactionMark.FromMatch(h)).ToList();
        Assert.True(marks.Count > 0, $"'{word}' is not on page {page}");
        return marks;
    }

    public static PdfDocument Open(RedactionResult result)
    {
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        return Reopen(result.Bytes);
    }

    /// <summary>Opens the bytes in Core and PdfPig, which both have to take them.</summary>
    public static PdfDocument Reopen(byte[] bytes, string? password = null)
    {
        var document = PdfDocument.Open(bytes, password);
        using (var pig = PigDocument.Open(bytes, new UglyToad.PdfPig.ParsingOptions { Password = password ?? "" }))
        {
            for (int i = 1; i <= pig.NumberOfPages; i++) pig.GetPage(i);
        }
        return document;
    }

    /// <summary>The file as Latin-1 text with every stream decoded and appended: what a search of "raw bytes and every stream" sees.</summary>
    public static string Everything(byte[] bytes, string? password = null)
    {
        var sb = new StringBuilder(Encoding.Latin1.GetString(bytes));
        using var document = PdfDocument.Open(bytes, password);
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not PdfStream stream) continue;
            sb.Append('\n');
            try
            {
                sb.Append(Encoding.Latin1.GetString(document.Data(stream)));
            }
            catch (PdfReadException)
            {
                sb.Append(Encoding.Latin1.GetString(document.RawData(stream)));
            }
        }
        return sb.ToString();
    }

    /// <summary>The text in any form it can take in a file: plain, UTF-16, or either as hex digits.</summary>
    public static bool Holds(byte[] bytes, string text, string? password = null)
    {
        string all = Everything(bytes, password);
        var wide = Encoding.BigEndianUnicode.GetBytes(text);
        string[] forms = [text, Encoding.Latin1.GetString(wide), Convert.ToHexString(Encoding.Latin1.GetBytes(text)), Convert.ToHexString(wide)];
        return forms.Any(f => all.Contains(f, StringComparison.OrdinalIgnoreCase));
    }

    public static string Pig(byte[] bytes, int page = 1)
    {
        using var pig = PigDocument.Open(bytes);
        return pig.GetPage(page).Text;
    }

    public static string Latin(PdfDocument document, int page = 0) => Encoding.Latin1.GetString(document.Pages[page].Contents());

    public static string Hex(string text) => Convert.ToHexString(Encoding.Latin1.GetBytes(text));
}
