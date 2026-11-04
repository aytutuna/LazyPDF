using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAFontTests
{
    private const string Show = "BT /F1 12 Tf 20 20 Td ";

    private static byte[] Arial()
    {
        SystemFonts.RequireArial();
        return File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf"));
    }

    private static string Descriptor(string flags = "32", string extra = "") =>
        $"<</Type /FontDescriptor /FontName /Arial /Flags {flags} /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 10 0 R {extra}>>";

    /// <summary>Arial as a simple TrueType font showing "Hi": H is 72 and i is 105.</summary>
    internal static byte[] Simple(string fontEntries = "/Encoding /WinAnsiEncoding", string flags = "32", int hWidth = 722, PdfALevel level = PdfALevel.A2b)
    {
        byte[] program = Arial();
        string widths = string.Join(' ', Enumerable.Range(72, 34).Select(c => c == 72 ? hWidth : c == 105 ? 222 : 0));
        return StandardsKit.Compliant(level, content: Show + "(Hi) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 72 /LastChar 105 /Widths [{widths}] /FontDescriptor 11 0 R {fontEntries}>>");
            pdf.Stream(10, $"/Length1 {program.Length}", program);
            pdf.Obj(11, Descriptor(flags));
        });
    }

    /// <summary>Arial as a Type0 font over Identity-H showing "Hi" by glyph index.</summary>
    internal static byte[] Composite(string cidFontEntries = "/CIDToGIDMap /Identity", string descriptorExtra = "", string type0Entries = "", PdfALevel level = PdfALevel.A2b, int hWidth = 722)
    {
        byte[] program = Arial();
        var tt = TrueTypeFont.TryParse(program)!;
        int h = tt.GlyphForCodePoint('H'), i = tt.GlyphForCodePoint('i');
        string codes = $"<{h:X4}{i:X4}>";
        return StandardsKit.Compliant(level, content: Show + codes + " Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [12 0 R] {type0Entries}>>");
            pdf.Stream(10, $"/Length1 {program.Length}", program);
            pdf.Obj(11, Descriptor(extra: descriptorExtra));
            pdf.Obj(12, $"<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 11 0 R /DW 1000 /W [{h} [{hWidth}] {i} [222]] {cidFontEntries}>>");
        });
    }

    [Fact]
    public void AFontThatIsNotEmbeddedIsReported()
    {
        byte[] file = StandardsKit.Compliant(content: Show + "(Hi) Tj ET", resources: "/Font <</F1 9 0 R>>",
            extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.11.4.1" && i.Where == "Font Helvetica");
        Assert.Contains("6.3.4", StandardsKit.Clauses(file, PdfALevel.A1b));
    }

    [Fact]
    public void AnEmbeddedTrueTypeFontPasses()
    {
        StandardsKit.AssertClean(Simple());
        StandardsKit.AssertClean(Composite());
    }

    [Fact]
    public void WidthsThatDisagreeWithTheProgramAreReported()
    {
        Assert.Contains(StandardsKit.Check(Simple(hWidth: 600)).Issues, i => i.Clause == "6.2.11.5" && i.Message.Contains("72"));
        Assert.Contains("6.3.6", StandardsKit.Clauses(Simple(hWidth: 600, level: PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains("6.2.11.5", StandardsKit.Clauses(Composite(hWidth: 500)));
        Assert.DoesNotContain("6.2.11.5", StandardsKit.Clauses(Simple(hWidth: 723)));
    }

    [Fact]
    public void ASimpleFontWithoutWidthsIsReported()
    {
        byte[] file = StandardsKit.Edited(Simple(), d =>
        {
            var font = (PdfDictionary)d.Get(9)!;
            font.Remove("Widths");
            font.Remove("FirstChar");
        });
        Assert.Contains("6.2.11.5", StandardsKit.Clauses(file));
    }

    [Fact]
    public void TrueTypeEncodingRulesDependOnTheSymbolicFlag()
    {
        Assert.Contains("6.2.11.6", StandardsKit.Clauses(Simple("/Encoding /WinAnsiEncoding", flags: "4")));
        Assert.Contains("6.2.11.6", StandardsKit.Clauses(Simple("")));
        Assert.Contains("6.2.11.6", StandardsKit.Clauses(Simple("/Encoding /StandardEncoding")));
        Assert.Contains("6.3.7", StandardsKit.Clauses(Simple("/Encoding /StandardEncoding", level: PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.2.11.6", StandardsKit.Clauses(Simple("/Encoding /MacRomanEncoding")));
        StandardsKit.AssertClean(Simple("", flags: "4"));
    }

    [Fact]
    public void ACidSetThatLeavesOutAGlyphShownIsReported()
    {
        var tt = TrueTypeFont.TryParse(Arial())!;
        byte[] empty = StandardsKit.Edited(Composite(), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            descriptor["CIDSet"] = d.Add(new PdfStream(new PdfDictionary(), new byte[16]));
        });
        Assert.Contains("6.2.11.4.2", StandardsKit.Clauses(empty));
        Assert.Contains("6.3.5", StandardsKit.Clauses(empty, PdfALevel.A1b));

        byte[] complete = StandardsKit.Edited(Composite(), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            var bits = new byte[(tt.GlyphCount + 7) / 8];
            for (int g = 0; g < tt.GlyphCount; g++) bits[g >> 3] |= (byte)(0x80 >> (g & 7));
            descriptor["CIDSet"] = d.Add(new PdfStream(new PdfDictionary(), bits));
        });
        Assert.DoesNotContain("6.2.11.4.2", StandardsKit.Clauses(complete));
    }

    [Fact]
    public void ACompositeFontNeedsAKnownCMapAndAnIdentityGlyphMap()
    {
        Assert.Contains("6.2.11.3.2", StandardsKit.Clauses(Composite(cidFontEntries: "")));
        byte[] unknown = StandardsKit.Edited(Composite(), d => ((PdfDictionary)d.Get(9)!)["Encoding"] = new PdfName("Invented-H"));
        Assert.Contains("6.2.11.3", string.Join(' ', StandardsKit.Clauses(unknown)));
        byte[] noInfo = StandardsKit.Edited(Composite(), d => ((PdfDictionary)d.Get(12)!).Remove("CIDSystemInfo"));
        Assert.Contains("6.2.11.3", string.Join(' ', StandardsKit.Clauses(noInfo)));
    }

    [Fact]
    public void LevelUNeedsAWayToUnicode()
    {
        byte[] without = Composite(level: PdfALevel.A2u);
        Assert.Contains("6.2.11.7.2", StandardsKit.Clauses(without, PdfALevel.A2u));
        Assert.DoesNotContain("6.2.11.7.2", StandardsKit.Clauses(without, PdfALevel.A2b));

        byte[] with = StandardsKit.Edited(without, d =>
        {
            var map = new SortedDictionary<int, string> { [1] = "H" };
            ((PdfDictionary)d.Get(9)!)["ToUnicode"] = d.Add(new PdfStream(new PdfDictionary(), ToUnicodeCMap.Write(map)));
        });
        Assert.DoesNotContain("6.2.11.7.2", StandardsKit.Clauses(with, PdfALevel.A2u));
    }

    [Fact]
    public void ASimpleLatinFontReachesUnicodeThroughItsGlyphNames()
    {
        Assert.DoesNotContain("6.2.11.7.2", StandardsKit.Clauses(Simple(level: PdfALevel.A2u), PdfALevel.A2u));
        Assert.Contains("6.2.11.7.2", StandardsKit.Clauses(Simple("/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [72 /g12] >>", level: PdfALevel.A2u), PdfALevel.A2u));
    }
}
