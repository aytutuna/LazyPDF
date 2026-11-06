using System.IO.Compression;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeFontTests
{
    private static readonly byte[] Arial = LoadArial();

    private static byte[] LoadArial()
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        return File.ReadAllBytes(path);
    }

    private static string Widths(TrueTypeFont tt) =>
        string.Join(' ', Enumerable.Range(32, 95).Select(c => tt.GetAdvance(tt.GlyphForCodePoint(c)) * 1000 / tt.UnitsPerEm));

    private static readonly string FontDescriptor =
        "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 7 0 R>>";

    private static void AddSimpleFont(TestPdf pdf)
    {
        var tt = TrueTypeFont.TryParse(Arial)!;
        pdf.Obj(5, $"<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 32 /LastChar 126 /Widths [{Widths(tt)}] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, FontDescriptor);
        pdf.Stream(7, $"/Filter /FlateDecode /Length1 {Arial.Length}", TestPdf.Deflate(Arial));
    }

    private static byte[] FontProgram(byte[] file)
    {
        using var after = PdfDocument.Open(file);
        var font = after.Dict(after.Dict(after.Pages[0].Resources, "Font"), "F1")!;
        return after.Data(after.Stream(after.Dict(font, "FontDescriptor"), "FontFile2")!);
    }

    [Fact]
    public void SimpleFontKeepsTheGlyphsOfItsText()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>", AddSimpleFont);
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { SubsetFonts = true });
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.SubsetFonts).Count);
        Assert.True(result.SizeAfter < result.SizeBefore / 5);
        Assert.Equal("Hello World", OptimizeKit.PigText(result.Bytes).Trim());
        Assert.Equal(OptimizeKit.EngineText(file), OptimizeKit.EngineText(result.Bytes));

        var trimmed = TrueTypeFont.TryParse(FontProgram(result.Bytes))!;
        var original = TrueTypeFont.TryParse(Arial)!;
        Assert.Equal(original.GlyphCount, trimmed.GlyphCount);
        foreach (char c in "Helo Wrd")
        {
            int gid = original.GlyphForCodePoint(c);
            Assert.Equal(gid, trimmed.GlyphForCodePoint(c));
            Assert.Equal(original.GetAdvance(gid), trimmed.GetAdvance(gid));
            Assert.Equal(original.GetBounds(gid), trimmed.GetBounds(gid));
        }
        Assert.Null(trimmed.GetBounds(original.GlyphForCodePoint('Z')));
    }

    [Fact]
    public void ProgramUsedOnTwoPagesKeepsTheGlyphsOfBoth()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 8 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 9 0 R>>");
        AddSimpleFont(pdf);
        pdf.Stream(8, "", "BT /F1 18 Tf 10 100 Td (abc) Tj ET");
        pdf.Stream(9, "", "BT /F1 18 Tf 10 100 Td (xyz) Tj ET");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { SubsetFonts = true });
        var trimmed = TrueTypeFont.TryParse(FontProgram(result.Bytes))!;
        var original = TrueTypeFont.TryParse(Arial)!;
        foreach (char c in "abcxyz") Assert.NotNull(trimmed.GetBounds(original.GlyphForCodePoint(c)));
        Assert.Null(trimmed.GetBounds(original.GlyphForCodePoint('Q')));
        Assert.Equal("abc\nxyz", OptimizeKit.PigText(result.Bytes).Trim());
    }

    [Fact]
    public void CompositeFontKeepsTheGlyphsOfItsCodes()
    {
        var tt = TrueTypeFont.TryParse(Arial)!;
        string hex = string.Concat("Hi".Select(c => tt.GlyphForCodePoint(c).ToString("X4")));
        byte[] file = OptimizeKit.Build($"BT /F1 18 Tf 10 100 Td <{hex}> Tj ET", "/Font <</F1 5 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [8 0 R]>>");
            pdf.Obj(8, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor 6 0 R /CIDToGIDMap /Identity /DW 600>>");
            pdf.Obj(6, FontDescriptor);
            pdf.Stream(7, $"/Filter /FlateDecode /Length1 {Arial.Length}", TestPdf.Deflate(Arial));
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { SubsetFonts = true });
        Assert.True(result.SizeAfter < result.SizeBefore / 5);
        using var after = PdfDocument.Open(result.Bytes);
        var font = after.Dict(after.Dict(after.Pages[0].Resources, "Font"), "F1")!;
        var descendant = (PdfDictionary)after.Resolve(after.Array(font, "DescendantFonts")!.Items[0])!;
        var trimmed = TrueTypeFont.TryParse(after.Data(after.Stream(after.Dict(descendant, "FontDescriptor"), "FontFile2")!))!;
        Assert.NotNull(trimmed.GetBounds(tt.GlyphForCodePoint('H')));
        Assert.Null(trimmed.GetBounds(tt.GlyphForCodePoint('Z')));
    }

    [Fact]
    public void ComponentsOfACompositeGlyphAreKept()
    {
        var tt = TrueTypeFont.TryParse(Arial)!;
        int accented = tt.GlyphForCodePoint('é');
        var trimmed = TrueTypeTrim.Trim(Arial, new HashSet<int> { accented });
        Assert.NotNull(trimmed);
        var small = TrueTypeFont.TryParse(trimmed!)!;
        Assert.Equal(tt.GetOutline(accented)!.Segments.Count, small.GetOutline(accented)!.Segments.Count);
        Assert.Null(small.GetBounds(tt.GlyphForCodePoint('Z')));
    }

    [Fact]
    public void FontWithNoGlyphsIsLeftAlone()
    {
        var tables = new (string Tag, byte[] Data)[] { ("glyf", new byte[4]), ("head", new byte[54]), ("loca", new byte[2]), ("maxp", new byte[6]) };
        var font = new List<byte> { 0, 1, 0, 0, 0, (byte)tables.Length, 0, 0, 0, 0, 0, 0 };
        int offset = 12 + 16 * tables.Length;
        foreach (var (tag, data) in tables)
        {
            font.AddRange(System.Text.Encoding.Latin1.GetBytes(tag));
            font.AddRange(new byte[] { 0, 0, 0, 0, 0, 0, (byte)(offset >> 8), (byte)offset, 0, 0, (byte)(data.Length >> 8), (byte)data.Length });
            offset += data.Length;
        }
        foreach (var (_, data) in tables) font.AddRange(data);
        Assert.Null(TrueTypeTrim.Trim(font.ToArray(), new HashSet<int> { 1 }));
    }

    [Fact]
    public void FontAlsoListedInTheFormIsLeftWhole()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", AddSimpleFont,
            catalogExtra: "/AcroForm <</Fields [] /DR <</Font <</Arial 5 0 R>>>>>>");
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { SubsetFonts = true });
        Assert.Equal(0, result.Steps.Single(s => s.Kind == OptimizeStepKind.SubsetFonts).Count);
        Assert.Contains(OptimizeText.LeftPartialFonts, result.Notes);
        Assert.Equal(Arial.Length, FontProgram(result.Bytes).Length);
    }

    [Fact]
    public void FontThatForbidsSubsettingIsLeftWhole()
    {
        var forbidding = (byte[])Arial.Clone();
        var tt = TrueTypeFont.TryParse(Arial)!;
        Assert.True(tt.SubsettingAllowed);
        int count = forbidding[4] << 8 | forbidding[5];
        for (int i = 0; i < count; i++)
        {
            int entry = 12 + 16 * i;
            if (System.Text.Encoding.Latin1.GetString(forbidding, entry, 4) != "OS/2") continue;
            int offset = forbidding[entry + 8] << 24 | forbidding[entry + 9] << 16 | forbidding[entry + 10] << 8 | forbidding[entry + 11];
            forbidding[offset + 8] = 0x01;
            forbidding[offset + 9] = 0x00;
        }
        Assert.False(TrueTypeFont.TryParse(forbidding)!.SubsettingAllowed);
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 10 100 Td (Hello) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 32 /LastChar 32 /Widths [278] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, FontDescriptor);
        pdf.Stream(7, "/Filter /FlateDecode", TestPdf.Deflate(forbidding));
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { SubsetFonts = true });
        Assert.Equal(0, result.Steps.Single(s => s.Kind == OptimizeStepKind.SubsetFonts).Count);
    }
}
