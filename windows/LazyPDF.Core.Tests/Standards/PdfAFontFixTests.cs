using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAFontFixTests
{
    private static PdfAConversion Convert(byte[] file, PdfALevel level = PdfALevel.A2b) =>
        new PdfAConverter(new SystemFonts()).Convert(file, level, StandardsKit.Date);

    private static byte[] Clean(PdfAConversion result)
    {
        Assert.Null(result.Refusal);
        Assert.True(result.Remaining.Count == 0, string.Join("\n", result.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        return result.Bytes!;
    }

    private static byte[] Page(string fontObject, string content, Action<TestPdf>? extra = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, fontObject);
        extra?.Invoke(pdf);
        return pdf.Finish("/Root 1 0 R");
    }

    private static PdfFont FontOf(PdfDocument document) =>
        PdfFont.Get(document, (PdfDictionary)document.Resolve(((PdfDictionary)document.Resolve(document.Pages[0].Resources!["Font"])!)["F1"])!);

    private static byte[] ArialPage(string fontEntries, string flags, string content, PdfALevel level = PdfALevel.A2b, Action<TestPdf>? more = null) =>
        FontPage("arial.ttf", fontEntries, flags, content, level, more);

    private static byte[] FontPage(string file, string fontEntries, string flags, string content, PdfALevel level, Action<TestPdf>? more = null, Func<byte[], byte[]>? patch = null)
    {
        byte[] program = File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), file));
        if (patch is not null) program = patch(program);
        return StandardsKit.Compliant(level, content: "BT /F1 12 Tf 20 20 Td " + content + " ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 39 /LastChar 39 /Widths [191] /FontDescriptor 11 0 R {fontEntries}>>");
            pdf.Stream(10, $"/Length1 {program.Length}", program);
            pdf.Obj(11, $"<</Type /FontDescriptor /FontName /ABCDEF+Arial /Flags {flags} /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 10 0 R>>");
            more?.Invoke(pdf);
        });
    }

    private static PdfDictionary Descriptor(PdfDocument document)
    {
        var font = FontOf(document).Dictionary;
        var holder = document.Array(font, "DescendantFonts") is { Items.Count: > 0 } kids ? (PdfDictionary)document.Resolve(kids.Items[0])! : font;
        return document.Dict(holder, "FontDescriptor")!;
    }

    [Fact]
    public void ADingbatsFontTheSourceCannotDrawStaysUnembeddedAndIsReported()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats>>", "BT /F1 12 Tf 20 100 Td (4) Tj ET");
        var result = Convert(file);
        Assert.NotNull(result.Bytes);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.4.1" && i.Where == "Font ZapfDingbats");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.False(FontOf(document).IsEmbedded);
    }

    [Fact]
    public void TextOfSeveralCharactersIsNotDrawnWithTheGlyphOfTheFirst()
    {
        SystemFonts.RequireArial();
        const string toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange " +
                                 "1 beginbfchar <41> <00660069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", pdf => pdf.Stream(6, "", toUnicode));
        var result = Convert(file);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.4.1");
    }

    [Fact]
    public void ACompositeCodeWithoutTextKeepsTheFontUnembedded()
    {
        SystemFonts.RequireArial();
        const string toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange " +
                                 "2 beginbfchar <0001> <0048> <0002> <0069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
        byte[] file = Page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00010003> Tj ET", pdf =>
        {
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 600>>");
            pdf.Obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>");
            pdf.Stream(8, "", toUnicode);
        });
        Assert.Contains(Convert(file).Remaining, i => i.Clause == "6.2.11.4.1");
    }

    [Fact]
    public void ASymbolFontStandInGivesEveryCodeAGlyph()
    {
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "symbol.ttf")), "symbol.ttf is not installed; this test needs it");
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol>>", "BT /F1 12 Tf 20 100 Td (abg) Tj ET");
        using var document = PdfDocument.Open(Clean(Convert(file)));
        Assert.All(FontOf(document).Decode("abg"u8), c => Assert.NotEqual(0, c.Cid));
    }

    [Fact]
    public void ANewSubsetGetsACidSetForPartOne()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET");
        using var document = PdfDocument.Open(Convert(file, PdfALevel.A1b).Bytes!);
        var descriptor = Descriptor(document);
        var bits = document.Data(document.Stream(descriptor, "CIDSet")!, 1 << 20);
        int cid = FontOf(document).Decode("H"u8)[0].Cid;
        Assert.NotEqual(0, bits[cid >> 3] & (0x80 >> (cid & 7)));
    }

    [Fact]
    public void AMissingOrShortCidSetOfASubsetIsWrittenAgainForPartOne()
    {
        byte[] subset = StandardsKit.Edited(PdfAFontTests.Composite(level: PdfALevel.A1b), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            descriptor["FontName"] = new PdfName("ABCDEF+Arial");
            descriptor["CIDSet"] = d.Add(new PdfStream(new PdfDictionary(), new byte[4]));
        });
        using var document = PdfDocument.Open(Convert(subset, PdfALevel.A1b).Bytes!);
        var bits = document.Data(document.Stream(Descriptor(document), "CIDSet")!, 1 << 20);
        int h = TrueTypeFont.TryParse(File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf")))!.GlyphForCodePoint('H');
        Assert.NotEqual(0, bits[h >> 3] & (0x80 >> (h & 7)));

        byte[] without = StandardsKit.Edited(PdfAFontTests.Composite(level: PdfALevel.A1b), d => ((PdfDictionary)d.Get(11)!)["FontName"] = new PdfName("ABCDEF+Arial"));
        using var written = PdfDocument.Open(Convert(without, PdfALevel.A1b).Bytes!);
        Assert.NotNull(written.Stream(Descriptor(written), "CIDSet"));
    }

    [Fact]
    public void AToUnicodeWithAHoleIsNotWrittenAtLevelU()
    {
        const string proc = "10 0 0 0 10 10 d1 0 0 10 10 re f";
        byte[] file = Page("<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /CharProcs <</A 6 0 R /g1 7 0 R>> " +
                           "/Encoding <</Type /Encoding /Differences [65 /A /g1]>> /FirstChar 65 /LastChar 66 /Widths [10 10]>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", pdf =>
        {
            pdf.Stream(6, "", proc);
            pdf.Stream(7, "", proc);
        });
        var result = Convert(file, PdfALevel.A2u);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.7.2");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.False(FontOf(document).HasToUnicode);
    }

    [Fact]
    public void ATrueTypeFontWithStandardEncodingKeepsItsGlyphsUnderWinAnsi()
    {
        byte[] file = ArialPage("/Encoding /StandardEncoding", "32", "(') Tj");
        using (var before = PdfDocument.Open(file)) Assert.Equal("’", FontOf(before).Decode("'"u8)[0].Unicode);
        using var after = PdfDocument.Open(Clean(Convert(file)));
        Assert.Equal("’", FontOf(after).Decode("'"u8)[0].Unicode);
    }

    [Fact]
    public void ASymbolicTrueTypeFontWhoseEncodingChangesGlyphsKeepsThemUnderNames()
    {
        byte[] file = ArialPage("/Encoding << /Type /Encoding /Differences [39 /quoteright] >>", "4", "(') Tj");
        using (var before = PdfDocument.Open(file)) Assert.Equal("’", FontOf(before).Decode("'"u8)[0].Unicode);
        using var after = PdfDocument.Open(Clean(Convert(file)));
        Assert.Equal("’", FontOf(after).Decode("'"u8)[0].Unicode);
    }

    private static byte[] ProgramOf(PdfDocument document) =>
        document.Data((PdfStream)document.Resolve(Descriptor(document)["FontFile2"])!, 1 << 26);

    private static byte[] CidSetOf(PdfDocument document) => document.Data(document.Stream(Descriptor(document), "CIDSet")!, 1 << 20);

    private static bool Listed(byte[] bits, int cid) => (cid >> 3) < bits.Length && (bits[cid >> 3] & (0x80 >> (cid & 7))) != 0;

    private static TrueTypeFont Installed(string file) =>
        TrueTypeFont.TryParse(File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), file)))!;

    private static string OneToUnicode(string text) =>
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange " +
        $"1 beginbfchar <41> <{text}> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";

    [Fact]
    public void ANewSubsetNamesEveryGlyphOfItsProgramInTheCidSet()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET");
        using var document = PdfDocument.Open(Clean(Convert(file, PdfALevel.A1b)));
        var program = TrueTypeFont.TryParse(ProgramOf(document))!;
        var bits = CidSetOf(document);
        var drawn = Enumerable.Range(1, program.GlyphCount - 1).Where(g => program.GlyphData(g).Length > 0).ToList();
        Assert.True(drawn.Count > 2);
        Assert.All(drawn, g => Assert.True(Listed(bits, g)));
    }

    [Fact]
    public void ACidSetOfOnlyTheShownGlyphsOfALargerProgramIsRebuiltAtPart2()
    {
        SystemFonts.RequireArial();
        var arial = Installed("arial.ttf");
        byte[] subset = StandardsKit.Edited(PdfAFontTests.Composite(), d =>
        {
            var descriptor = (PdfDictionary)d.Get(11)!;
            descriptor["FontName"] = new PdfName("ABCDEF+Arial");
            var bits = new byte[8192];
            foreach (int g in new[] { arial.GlyphForCodePoint('H'), arial.GlyphForCodePoint('i') }) bits[g >> 3] |= (byte)(0x80 >> (g & 7));
            descriptor["CIDSet"] = d.Add(new PdfStream(new PdfDictionary(), bits));
        });
        using var document = PdfDocument.Open(Clean(Convert(subset)));
        Assert.True(Listed(CidSetOf(document), arial.GlyphForCodePoint('A')));
    }

    [Fact]
    public void ACidSetIsBuiltForAFontWithACidToGidMapStream()
    {
        SystemFonts.RequireArial();
        var arial = Installed("arial.ttf");
        int h = arial.GlyphForCodePoint('H'), i = arial.GlyphForCodePoint('i');
        byte[] subset = StandardsKit.Edited(PdfAFontTests.Composite(level: PdfALevel.A1b), d =>
        {
            ((PdfDictionary)d.Get(11)!)["FontName"] = new PdfName("ABCDEF+Arial");
            var map = new byte[(Math.Max(h, i) + 1) * 2];
            foreach (int g in new[] { h, i }) (map[2 * g], map[2 * g + 1]) = ((byte)(g >> 8), (byte)g);
            ((PdfDictionary)d.Get(12)!)["CIDToGIDMap"] = d.Add(new PdfStream(new PdfDictionary(), map));
        });
        using var document = PdfDocument.Open(Clean(Convert(subset, PdfALevel.A1b)));
        var bits = CidSetOf(document);
        Assert.True(Listed(bits, h) && Listed(bits, i));
    }

    [Fact]
    public void AToUnicodeThatMapsToNulIsRewrittenFromTheEncoding()
    {
        byte[] file = ArialPage("/Encoding /WinAnsiEncoding /ToUnicode 12 0 R", "32", "(A) Tj", PdfALevel.A2u, pdf => pdf.Stream(12, "", OneToUnicode("0000")));
        using (var before = PdfDocument.Open(file)) Assert.Equal("\0", FontOf(before).Decode("A"u8)[0].Unicode);
        using var after = PdfDocument.Open(Clean(Convert(file, PdfALevel.A2u)));
        Assert.Equal("A", FontOf(after).Decode("A"u8)[0].Unicode);
    }

    [Fact]
    public void AToUnicodeWithAHoleThatNothingFillsIsDroppedAndReported()
    {
        const string proc = "10 0 0 0 10 10 d1 0 0 10 10 re f";
        byte[] file = Page("<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /CharProcs <</A 6 0 R /g1 7 0 R>> " +
                           "/Encoding <</Type /Encoding /Differences [65 /A /g1]>> /FirstChar 65 /LastChar 66 /Widths [10 10] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", pdf =>
        {
            pdf.Stream(6, "", proc);
            pdf.Stream(7, "", proc);
            pdf.Stream(8, "", OneToUnicode("0041"));
        });
        var result = Convert(file, PdfALevel.A2u);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.7.2");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.False(FontOf(document).HasToUnicode);
    }

    [Fact]
    public void ACodeTheEncodingHasNoNameForKeepsItsGlyphUnderWinAnsi()
    {
        byte[] standard = ArialPage("/Encoding /StandardEncoding", "32", "<E0> Tj");
        using (var before = PdfDocument.Open(standard)) Assert.Equal("‡", FontOf(before).Decode([0xE0])[0].Unicode);
        using (var after = PdfDocument.Open(Clean(Convert(standard)))) Assert.Equal("‡", FontOf(after).Decode([0xE0])[0].Unicode);

        byte[] unnamed = ArialPage("/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [224 /foo] >>", "32", "<E0> Tj");
        using (var before = PdfDocument.Open(unnamed)) Assert.Equal("‡", FontOf(before).Decode([0xE0])[0].Unicode);
        using (var after = PdfDocument.Open(Clean(Convert(unnamed)))) Assert.Equal("‡", FontOf(after).Decode([0xE0])[0].Unicode);

        byte[] levelU = ArialPage("/Encoding /StandardEncoding", "32", "<80> Tj", PdfALevel.A2u);
        using (var before = PdfDocument.Open(levelU)) Assert.Equal("Ä", FontOf(before).Decode([0x80])[0].Unicode);
        using (var after = PdfDocument.Open(Clean(Convert(levelU, PdfALevel.A2u)))) Assert.Equal("Ä", FontOf(after).Decode([0x80])[0].Unicode);
    }

    [Fact]
    public void ASymbolicFontWithoutAUnicodeCmapKeepsItsEncodingAndIsReported()
    {
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "symbol.ttf")), "symbol.ttf is not installed; this test needs it");
        byte[] file = FontPage("symbol.ttf", "/Encoding << /Type /Encoding /Differences [65 /B] >>", "4", "(A) Tj", PdfALevel.A2b);
        var result = Convert(file);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.6");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.Equal(4, document.Integer(Descriptor(document), "Flags"));
    }

    [Fact]
    public void ASymbolFontStandInDrawsTheGlyphTheEncodingNames()
    {
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "symbol.ttf")), "symbol.ttf is not installed; this test needs it");
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol /Encoding <</Type /Encoding /Differences [65 /beta]>>>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET");
        using var document = PdfDocument.Open(Clean(Convert(file)));
        var symbol = Installed("symbol.ttf");
        int beta = symbol.GlyphForCmap(3, 0, 0x62) is > 0 and var glyph ? glyph : symbol.GlyphForCmap(3, 0, 0xF062);
        var drawn = FontOf(document).Decode("A"u8)[0];
        Assert.Equal("β", drawn.Unicode);
        Assert.Equal(symbol.GetAdvance(beta) * 1000.0 / symbol.UnitsPerEm, drawn.Width, 0.5);
    }

    [Fact]
    public void ACodeBelow32TheEncodingNamesKeepsTheFontUnembedded()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /g1]>>>>", "BT /F1 12 Tf 20 100 Td <0141> Tj ET");
        var result = Convert(file, PdfALevel.A2u);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.4.1");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.False(FontOf(document).IsEmbedded);
    }

    [Fact]
    public void AReplacementTakesTheTextOfABadToUnicodeFromTheEncoding()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET",
            pdf => pdf.Stream(6, "", OneToUnicode("0000")));
        using var document = PdfDocument.Open(Clean(Convert(file, PdfALevel.A2u)));
        Assert.Equal("A", FontOf(document).Decode("A"u8)[0].Unicode);
    }

    private static byte[] Type1CPage(string charSet, string encoding, PdfALevel level)
    {
        byte[] program = CffBuilder.NameKeyed();
        return StandardsKit.Compliant(level, content: "BT /F1 12 Tf 20 20 Td (A) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 65 /LastChar 65 /Widths [500] /FontDescriptor 11 0 R {encoding}>>");
            pdf.Stream(10, "/Subtype /Type1C", program);
            pdf.Obj(11, $"<</Type /FontDescriptor /FontName /ABCDEF+Test /Flags 32 /FontBBox [0 0 200 200] /ItalicAngle 0 /Ascent 200 /Descent 0 /CapHeight 200 /StemV 80 /FontFile3 10 0 R {charSet}>>");
        });
    }

    private static string CharSetOf(PdfDocument document) =>
        System.Text.Encoding.Latin1.GetString(((PdfString)document.Resolve(Descriptor(document)["CharSet"])!).Bytes);

    [Fact]
    public void ACharSetThatMissesGlyphsIsRebuiltWithoutNotdef()
    {
        byte[] file = Type1CPage("/CharSet (/A)", "/Encoding /WinAnsiEncoding", PdfALevel.A2b);
        using var document = PdfDocument.Open(Clean(Convert(file)));
        Assert.Equal("/A/B/custom", CharSetOf(document));

        byte[] without = Type1CPage("", "/Encoding /WinAnsiEncoding", PdfALevel.A1b);
        using var written = PdfDocument.Open(Clean(Convert(without, PdfALevel.A1b)));
        Assert.Equal("/A/B/custom", CharSetOf(written));
    }

    [Fact]
    public void ACharSetNamesAShownGlyphTheProgramLacks()
    {
        byte[] file = Type1CPage("/CharSet (/A)", "/Encoding << /Type /Encoding /Differences [65 /foo] >>", PdfALevel.A2b);
        using var document = PdfDocument.Open(Clean(Convert(file)));
        Assert.Contains("/foo", CharSetOf(document));
    }

    // Renumbers every cmap subtable but (1,0) so that a reader finds glyphs by name only through MacRoman.
    private static byte[] MacOnly(byte[] font)
    {
        byte[] copy = (byte[])font.Clone();
        int tables = copy[4] << 8 | copy[5];
        for (int i = 0; i < tables; i++)
        {
            int entry = 12 + 16 * i;
            if (System.Text.Encoding.ASCII.GetString(copy, entry, 4) != "cmap") continue;
            int cmap = copy[entry + 8] << 24 | copy[entry + 9] << 16 | copy[entry + 10] << 8 | copy[entry + 11];
            int count = copy[cmap + 2] << 8 | copy[cmap + 3];
            for (int k = 0; k < count; k++)
            {
                int record = cmap + 4 + 8 * k;
                if ((copy[record] << 8 | copy[record + 1]) == 1 && (copy[record + 2] << 8 | copy[record + 3]) == 0) continue;
                copy[record] = 0;
                copy[record + 1] = 9;
            }
        }
        return copy;
    }

    [Fact]
    public void AConvertedFontKeepsItsToUnicodeWhenConvertedAgainToLevelU()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi there) Tj ET");
        byte[] first = Clean(Convert(file));
        using (var middle = PdfDocument.Open(first)) Assert.Equal("Hi there", FontOf(middle).ToText("Hi there"u8));
        using var document = PdfDocument.Open(Clean(Convert(first, PdfALevel.A2u)));
        Assert.True(FontOf(document).HasToUnicode);
        Assert.Equal("Hi there", FontOf(document).ToText("Hi there"u8));
    }

    [Fact]
    public void AToUnicodeOfALatinFontWithAHoleIsKept()
    {
        byte[] file = ArialPage("/Encoding /WinAnsiEncoding /ToUnicode 12 0 R", "32", "<4101> Tj", PdfALevel.A2u, pdf => pdf.Stream(12, "", OneToUnicode("0041")));
        using var document = PdfDocument.Open(Clean(Convert(file, PdfALevel.A2u)));
        Assert.True(FontOf(document).HasToUnicode);
        Assert.Equal("A", FontOf(document).Decode([0x41])[0].Unicode);
    }

    [Fact]
    public void ACompositeFontEmbeddedFromTheEncodingGetsAToUnicodeWithoutHoles()
    {
        SystemFonts.RequireArial();
        const string toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange " +
                                 "1 beginbfchar <0022> <0000> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
        byte[] file = Page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00220023> Tj ET", pdf =>
        {
            pdf.Obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 7 0 R /DW 600>>");
            pdf.Obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>");
            pdf.Stream(8, "", toUnicode);
        });
        using var document = PdfDocument.Open(Clean(Convert(file, PdfALevel.A2u)));
        Assert.All(FontOf(document).Decode([0, 0x22, 0, 0x23]), c => Assert.True(c.Unicode is { Length: > 0 } && c.Unicode != " "));
    }

    [Fact]
    public void AControlCodeWithoutAGlyphNameKeepsTheFontUnembedded()
    {
        SystemFonts.RequireArial();
        byte[] file = Page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td <41094B> Tj ET");
        var result = Convert(file);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.4.1");
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.False(FontOf(document).IsEmbedded);
    }

    [Fact]
    public void ANameThatReachesAnotherGlyphThroughMacRomanIsNotRewrittenWithoutAUnicodeCmap()
    {
        byte[] standard = FontPage("arial.ttf", "/Encoding /StandardEncoding", "32", "(') Tj", PdfALevel.A2b, patch: MacOnly);
        var result = Convert(standard);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.11.6");
        using (var document = PdfDocument.Open(result.Bytes!)) Assert.Equal("StandardEncoding", document.Name(FontOf(document).Dictionary, "Encoding"));

        byte[] listed = FontPage("arial.ttf", "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [39 /quoteright] >>", "32", "(') Tj", PdfALevel.A2b, patch: MacOnly);
        using var kept = PdfDocument.Open(Convert(listed).Bytes!);
        Assert.NotNull(kept.Array(kept.Dict(FontOf(kept).Dictionary, "Encoding")!, "Differences"));
    }

    [Fact]
    public void ASymbolicFontWithoutAUnicodeCmapIsNotMadeNonSymbolic()
    {
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "symbol.ttf")), "symbol.ttf is not installed; this test needs it");
        byte[] file = FontPage("symbol.ttf", "/Encoding /MacRomanEncoding", "4", "<80> Tj", PdfALevel.A2b);
        var result = Convert(file);
        using var document = PdfDocument.Open(result.Bytes!);
        Assert.Equal(4, document.Integer(Descriptor(document), "Flags"));
    }
}
