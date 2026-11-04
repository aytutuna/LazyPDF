using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfASubsetTests
{
    private static byte[] Subset(PdfALevel level, Action<PdfDocument, PdfDictionary>? edit = null) =>
        StandardsKit.Edited(PdfAFontTests.Composite(level: level), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            descriptor["FontName"] = new PdfName("ABCDEF+Arial");
            edit?.Invoke(d, descriptor);
        });

    private static PdfStream Bits(params int[] glyphs)
    {
        var bits = new byte[8192];
        foreach (int g in glyphs) bits[g >> 3] |= (byte)(0x80 >> (g & 7));
        return new PdfStream(new PdfDictionary(), bits);
    }

    private static byte[] Program() => File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf"));

    [Fact]
    public void Part1AsksForACidSetInASubset()
    {
        SystemFonts.RequireArial();
        Assert.Contains(StandardsKit.Check(Subset(PdfALevel.A1b), PdfALevel.A1b).Issues, i => i.Clause == "6.3.5" && i.Message.Contains("no /CIDSet"));
        Assert.DoesNotContain("6.2.11.4.2", StandardsKit.Clauses(Subset(PdfALevel.A2b)));
        Assert.DoesNotContain("6.3.5", StandardsKit.Clauses(PdfAFontTests.Composite(level: PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void ACidSetThatListsOnlyTheShownGlyphsOfALargerProgramIsReported()
    {
        SystemFonts.RequireArial();
        var tt = TrueTypeFont.TryParse(Program())!;
        int[] shown = [tt.GlyphForCodePoint('H'), tt.GlyphForCodePoint('i')];
        byte[] only = Subset(PdfALevel.A2b, (d, descriptor) => descriptor["CIDSet"] = d.Add(Bits(shown)));
        Assert.Contains(StandardsKit.Check(only).Issues, i => i.Clause == "6.2.11.4.2" && i.Message.Contains("font program"));
        Assert.Contains("6.3.5", StandardsKit.Clauses(Subset(PdfALevel.A1b, (d, descriptor) => descriptor["CIDSet"] = d.Add(Bits(shown))), PdfALevel.A1b));

        byte[] all = Subset(PdfALevel.A2b, (d, descriptor) => descriptor["CIDSet"] = d.Add(Bits([.. Enumerable.Range(0, tt.GlyphCount)])));
        StandardsKit.AssertClean(all);
        StandardsKit.AssertClean(Subset(PdfALevel.A1b, (d, descriptor) => descriptor["CIDSet"] = d.Add(Bits([.. Enumerable.Range(0, tt.GlyphCount)]))), PdfALevel.A1b);
    }

    [Fact]
    public void AnOpenTypeFontFileCameWithPdf16()
    {
        SystemFonts.RequireArial();
        byte[] file = StandardsKit.Edited(PdfAFontTests.Composite(level: PdfALevel.A1b), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            var program = (PdfStream)d.Get(10)!;
            program.Dictionary["Subtype"] = new PdfName("OpenType");
            descriptor["FontFile3"] = descriptor["FontFile2"]!;
            descriptor.Remove("FontFile2");
        });
        Assert.Contains(StandardsKit.Check(file, PdfALevel.A1b).Issues, i => i.Clause == "6.3.4" && i.Message.Contains("/Subtype"));
        Assert.DoesNotContain(StandardsKit.Check(file, PdfALevel.A2b).Issues, i => i.Message.Contains("/Subtype"));
    }

    [Fact]
    public void AFontThatShowsNothingIsNotHeldToTheFontRules()
    {
        byte[] listed = StandardsKit.Compliant(resources: "/Font <</F1 9 0 R>>", extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"));
        StandardsKit.AssertClean(listed);
        byte[] form = StandardsKit.Compliant(catalog: "/AcroForm << /Fields [] /DR << /Font << /Helv 9 0 R >> >> >>",
            extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"));
        StandardsKit.AssertClean(form);
    }

    [Fact]
    public void TextInRenderModeThreeNeedsNoEmbeddedFontFromPart2()
    {
        byte[] file = StandardsKit.Compliant(content: "BT /F1 12 Tf 3 Tr 20 20 Td (Hi) Tj ET", resources: "/Font <</F1 9 0 R>>",
            extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"));
        StandardsKit.AssertClean(file);
        Assert.Contains("6.3.4", StandardsKit.Clauses(file, PdfALevel.A1b));
        byte[] drawn = StandardsKit.Compliant(content: "BT /F1 12 Tf 0 Tr 20 20 Td (Hi) Tj ET", resources: "/Font <</F1 9 0 R>>",
            extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"));
        Assert.Contains("6.2.11.4.1", StandardsKit.Clauses(drawn));
    }

    private static byte[] Type1CPage(string name, string charSet, PdfALevel level)
    {
        byte[] program = CffBuilder.NameKeyed();
        return StandardsKit.Compliant(level, content: "BT /F1 12 Tf 20 20 Td (A) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Font /Subtype /Type1 /BaseFont /{name} /FirstChar 65 /LastChar 65 /Widths [500] /FontDescriptor 11 0 R /Encoding /WinAnsiEncoding>>");
            pdf.Stream(10, "/Subtype /Type1C", program);
            pdf.Obj(11, $"<</Type /FontDescriptor /FontName /{name} /Flags 32 /FontBBox [0 0 200 200] /ItalicAngle 0 /Ascent 200 /Descent 0 /CapHeight 200 /StemV 80 /FontFile3 10 0 R {charSet}>>");
        });
    }

    [Fact]
    public void ACharSetMustNameEveryGlyphOfTheProgram()
    {
        Assert.Contains(StandardsKit.Check(Type1CPage("ABCDEF+Test", "/CharSet (/A)", PdfALevel.A2b)).Issues, i => i.Clause == "6.2.11.4.2" && i.Message == PdfAText.CharSetIncomplete);
        Assert.Contains(StandardsKit.Check(Type1CPage("ABCDEF+Test", "/CharSet (/A)", PdfALevel.A1b), PdfALevel.A1b).Issues, i => i.Clause == "6.3.5" && i.Message == PdfAText.CharSetIncomplete);
        Assert.DoesNotContain("6.2.11.4.2", StandardsKit.Clauses(Type1CPage("ABCDEF+Test", "/CharSet (/A/B/custom)", PdfALevel.A2b)));
        Assert.DoesNotContain("6.3.5", StandardsKit.Clauses(Type1CPage("ABCDEF+Test", "/CharSet (/A/B/custom)", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void Part1AsksForACharSetInASubsetAndLaterPartsDoNot()
    {
        Assert.Contains(StandardsKit.Check(Type1CPage("ABCDEF+Test", "", PdfALevel.A1b), PdfALevel.A1b).Issues, i => i.Clause == "6.3.5" && i.Message == PdfAText.CharSetMissing);
        Assert.DoesNotContain("6.2.11.4.2", StandardsKit.Clauses(Type1CPage("ABCDEF+Test", "", PdfALevel.A2b)));
    }

    [Fact]
    public void Part1HoldsOnlyASubsetToItsSets()
    {
        Assert.DoesNotContain("6.3.5", StandardsKit.Clauses(Type1CPage("Test", "", PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.3.5", StandardsKit.Clauses(Type1CPage("Test", "/CharSet (/A)", PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains("6.2.11.4.2", StandardsKit.Clauses(Type1CPage("Test", "/CharSet (/A)", PdfALevel.A2b)));
    }
}
