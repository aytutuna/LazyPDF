using System.Text;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>PDFs with exact text for the text tests: Helvetica half an em wide everywhere, with a few codes mapped to the awkward characters.</summary>
internal static class TextPdf
{
    // fi ligature, soft hyphen, a character outside the BMP; \u0080 has no text at all.
    private static readonly (int Code, string Text)[] Codes = [(1, "fi"), (2, "\u00AD"), (3, "\U0001F600")];

    public static string Line(double x, double y, string text, double size = 10, string font = "F1") =>
        $"BT /{font} {size} Tf {x} {y} Td ({Escape(text)}) Tj ET\n";

    private static string Escape(string text)
    {
        var sb = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            string s = rune.ToString();
            int code = s switch { "\uFB01" => 1, "\u00AD" => 2, "\U0001F600" => 3, "\u0080" => 128, _ => s[0] };
            sb.Append('\\').Append(Convert.ToString(code, 8).PadLeft(3, '0'));
        }
        return sb.ToString();
    }

    public static byte[] Pdf(params string[] pages) => Pdf("", pages);

    // pageEntries go into every page dictionary, for a /Rotate or a /CropBox.
    public static byte[] Pdf(string pageEntries, string[] pages)
    {
        var objects = new List<string>();
        int fontObject = 3 + pages.Length * 2;
        var kids = string.Join(" ", Enumerable.Range(0, pages.Length).Select(p => $"{3 + p * 2} 0 R"));
        var widths = string.Join(" ", Enumerable.Repeat("500", 256));
        var map = new Dictionary<int, string>(Codes.ToDictionary(c => c.Code, c => c.Text));
        for (int c = 32; c < 127; c++) map[c] = ((char)c).ToString();
        var cmap = new StringBuilder("/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange ");
        cmap.Append(map.Count).Append(" beginbfchar ");
        foreach (var (code, text) in map) cmap.Append($"<{code:X2}> <{string.Concat(text.Select(ch => ((int)ch).ToString("X4")))}> ");
        cmap.Append("endbfchar endcmap");

        var body = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        void Obj(string text)
        {
            offsets.Add(body.Length);
            body.Append($"{offsets.Count} 0 obj\n{text}\nendobj\n");
        }
        Obj("<</Type /Catalog /Pages 2 0 R>>");
        Obj($"<</Type /Pages /Kids [{kids}] /Count {pages.Length} /MediaBox [0 0 600 800]>>");
        foreach (var (content, p) in pages.Select((c, p) => (c, p)))
        {
            Obj($"<</Type /Page /Parent 2 0 R /Contents {4 + p * 2} 0 R {pageEntries} /Resources <</Font <</F1 {fontObject} 0 R>>>>>>");
            Obj($"<</Length {content.Length}>>\nstream\n{content}\nendstream");
        }
        Obj($"<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 0 /LastChar 255 /Widths [{widths}] /ToUnicode {fontObject + 1} 0 R>>");
        Obj($"<</Length {cmap.Length}>>\nstream\n{cmap}\nendstream");
        int xref = body.Length;
        body.Append($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (int o in offsets) body.Append($"{o:D10} 00000 n \n");
        body.Append($"trailer\n<</Size {offsets.Count + 1} /Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.Latin1.GetBytes(body.ToString());
    }

    public static TextPage[] Pages(params string[] contents)
    {
        var document = PdfDocument.Open(Pdf(contents));
        return [.. contents.Select((_, p) => TextPage.Create(document, document.Pages[p]))];
    }

    public static PageUiaText Page(string content) => PageUiaText.Of(Pages(content)[0]);
}
