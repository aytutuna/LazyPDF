using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

internal static class EditFixtures
{
    public static byte[] Arial()
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(System.IO.File.Exists(path), "arial.ttf is not installed; these tests need it");
        return System.IO.File.ReadAllBytes(path);
    }

    /// <summary>A page with one line drawn in a Type0 font that holds just the letters of the line.</summary>
    public static byte[] EmbeddedLine(string line)
    {
        var scratch = PdfDocument.Open(TestPdf.Simple(1));
        var draw = new PdfFontEmbedder(scratch, new EditArialSource()).Add("Arial", FontStyles.Regular, [line], embed: true)!;
        var content = new ContentWriter().BeginText().Font("F1", 12).MoveText(10, 100).Show(draw.Encode(line)).EndText().ToArray();
        return OnePage(scratch, draw.Reference, content);
    }

    private static byte[] OnePage(PdfDocument scratch, PdfReference font, byte[] content)
    {
        var page = scratch.Pages[0];
        var resources = new PdfDictionary();
        var fonts = new PdfDictionary();
        fonts["F1"] = font;
        resources["Font"] = fonts;
        page.Dictionary["Resources"] = resources;
        page.Dictionary["Contents"] = scratch.Add(new PdfStream(new PdfDictionary(), content));
        return scratch.SaveRewrite();
    }

    /// <summary>A page with one line in a Type0 font holding the whole of Arial under its plain name, so it has no subset tag.</summary>
    public static byte[] FullCidLine(string line)
    {
        var font = Arial();
        var tt = TrueTypeFont.TryParse(font)!;
        var scratch = PdfDocument.Open(TestPdf.Simple(1));
        var codes = line.EnumerateRunes().Select(r => r.Value).Distinct().ToDictionary(r => r, r => tt.GlyphForCodePoint(r));
        var program = new PdfDictionary();
        program["Filter"] = new PdfName("FlateDecode");
        program["Length1"] = new PdfNumber(font.Length);
        var file = scratch.Add(new PdfStream(program, PdfFilterEncoders.Flate(font)));
        var descriptor = new PdfDictionary();
        descriptor["Type"] = new PdfName("FontDescriptor");
        descriptor["FontName"] = new PdfName("Arial");
        descriptor["Flags"] = new PdfNumber(32);
        descriptor["FontBBox"] = new PdfArray([new PdfNumber(-665), new PdfNumber(-325), new PdfNumber(2000), new PdfNumber(1006)]);
        descriptor["ItalicAngle"] = new PdfNumber(0);
        descriptor["Ascent"] = new PdfNumber(905);
        descriptor["Descent"] = new PdfNumber(-212);
        descriptor["CapHeight"] = new PdfNumber(716);
        descriptor["StemV"] = new PdfNumber(80);
        descriptor["FontFile2"] = file;
        var widths = new List<PdfObject>();
        foreach (var (_, gid) in codes.OrderBy(c => c.Value))
        {
            widths.Add(new PdfNumber(gid));
            widths.Add(new PdfArray([new PdfNumber(Math.Round(tt.GetAdvance(gid) * 1000.0 / tt.UnitsPerEm))]));
        }
        var info = new PdfDictionary();
        info["Registry"] = new PdfString("Adobe"u8.ToArray(), false);
        info["Ordering"] = new PdfString("Identity"u8.ToArray(), false);
        info["Supplement"] = new PdfNumber(0L);
        var cid = new PdfDictionary();
        cid["Type"] = new PdfName("Font");
        cid["Subtype"] = new PdfName("CIDFontType2");
        cid["BaseFont"] = new PdfName("Arial");
        cid["CIDSystemInfo"] = info;
        cid["FontDescriptor"] = scratch.Add(descriptor);
        cid["DW"] = new PdfNumber(1000L);
        cid["W"] = new PdfArray(widths);
        cid["CIDToGIDMap"] = new PdfName("Identity");
        var cmap = ToUnicodeCMap.Write(codes.Select(c => new KeyValuePair<int, string>(c.Value, char.ConvertFromUtf32(c.Key))));
        var toUnicode = new PdfDictionary();
        toUnicode["Filter"] = new PdfName("FlateDecode");
        var type0 = new PdfDictionary();
        type0["Type"] = new PdfName("Font");
        type0["Subtype"] = new PdfName("Type0");
        type0["BaseFont"] = new PdfName("Arial");
        type0["Encoding"] = new PdfName("Identity-H");
        type0["DescendantFonts"] = new PdfArray([scratch.Add(cid)]);
        type0["ToUnicode"] = scratch.Add(new PdfStream(toUnicode, PdfFilterEncoders.Flate(cmap)));
        var encoded = line.EnumerateRunes().SelectMany(r => new[] { (byte)(codes[r.Value] >> 8), (byte)codes[r.Value] }).ToArray();
        var content = new ContentWriter().BeginText().Font("F1", 12).MoveText(10, 100).Show(encoded).EndText().ToArray();
        return OnePage(scratch, scratch.Add(type0), content);
    }
}
