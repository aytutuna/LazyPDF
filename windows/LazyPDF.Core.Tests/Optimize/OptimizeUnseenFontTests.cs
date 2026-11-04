using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeUnseenFontTests
{
    private static readonly byte[] Arial = File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf"));

    private static readonly string Descriptor =
        "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 7 0 R>>";

    private static string Font(string extra = "", string baseFont = "Arial") =>
        $"/Subtype /TrueType /BaseFont /{baseFont} /FirstChar 32 /LastChar 32 /Widths [278] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding {extra}";

    private static void Program(TestPdf pdf)
    {
        pdf.Obj(6, Descriptor);
        pdf.Stream(7, $"/Filter /FlateDecode /Length1 {Arial.Length}", TestPdf.Deflate(Arial));
    }

    private static readonly OptimizeOptions Subset = OptimizeKit.Off with { SubsetFonts = true };

    private static PdfOptimizer Optimizer(byte[] file, out PdfDocument document)
    {
        document = PdfDocument.Open(file);
        return new PdfOptimizer(document);
    }

    private static byte[] Largest(byte[] file)
    {
        using var after = PdfDocument.Open(file);
        var programs = after.ObjectNumbers.Select(n => after.Get(n)).OfType<PdfStream>()
            .Where(s => s.Dictionary.ContainsKey("Length1")).Select(s => after.Data(s)).ToList();
        return programs.OrderByDescending(p => p.Length).First();
    }

    private static bool Has(byte[] program, char c) =>
        TrueTypeFont.TryParse(program)!.GetBounds(TrueTypeFont.TryParse(Arial)!.GlyphForCodePoint(c)) is not null;

    [Fact]
    public void A_font_used_only_inside_a_soft_mask_group_keeps_its_glyphs()
    {
        byte[] file = OptimizeKit.Build("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</GS1 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F2 5 0 R>>>>",
                "BT /F2 18 Tf 10 50 Td (Zed) Tj ET");
        });
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        var font = Largest(result.Bytes);
        Assert.True(Has(font, 'Z') && Has(font, 'H'));
        Assert.Contains(OptimizeText.LeftPartialFonts, result.Notes);
    }

    [Fact]
    public void A_font_used_only_by_a_hidden_appearance_state_keeps_its_glyphs()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources <</Font <</F2 5 0 R>>>>", "BT /F2 12 Tf 2 2 Td (Q) Tj ET");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "");
        }, pageExtra: "/Annots [8 0 R]");
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        Assert.True(Has(Largest(result.Bytes), 'Q'));
    }

    [Fact]
    public void A_font_still_shrinks_when_every_table_naming_it_was_walked()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET /Fm0 Do", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F2 5 0 R>>>>", "BT /F2 12 Tf 2 2 Td (abc) Tj ET");
        });
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        var font = Largest(result.Bytes);
        Assert.True(Has(font, 'a') && Has(font, 'H'));
        Assert.False(Has(font, 'Z'));
    }

    private static byte[] TwoPages(string firstFonts, string secondFonts, Action<TestPdf> more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 8 0 R /Resources <</Font {firstFonts}>>>>");
        pdf.Obj(4, $"<</Type /Page /Parent 2 0 R /Contents 9 0 R /Resources <</Font {secondFonts}>>>>");
        pdf.Stream(8, "", "BT /F1 18 Tf 10 100 Td (abc) Tj ET");
        pdf.Stream(9, "", "BT /F2 18 Tf 10 100 Td (xyz) Tj ET");
        Program(pdf);
        more(pdf);
        return pdf.Finish();
    }

    [Fact]
    public void A_font_written_directly_in_a_table_counts_toward_a_shared_program()
    {
        byte[] file = TwoPages("<</F1 5 0 R>>", $"<</F2 <</Type /Font {Font()}>>>>", pdf => pdf.Obj(5, "<</Type /Font " + Font() + ">>"));
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        var font = Largest(result.Bytes);
        Assert.True(Has(font, 'a') && Has(font, 'x') && Has(font, 'z'));
        Assert.False(Has(font, 'Q'));
    }

    [Fact]
    public void A_font_without_a_type_counts_toward_a_shared_program()
    {
        byte[] file = TwoPages("<</F1 5 0 R>>", "<</F2 10 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            pdf.Obj(10, "<<" + Font() + ">>");
        });
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        var font = Largest(result.Bytes);
        Assert.True(Has(font, 'a') && Has(font, 'x') && Has(font, 'z'));
    }

    [Fact]
    public void A_program_shared_with_a_subset_tagged_font_is_left_whole()
    {
        byte[] file = TwoPages("<</F1 5 0 R>>", "<</F2 10 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            pdf.Obj(10, "<</Type /Font " + Font(baseFont: "ABCDEF+Arial") + ">>");
        });
        var result = Optimizer(file, out var document).Run(Subset);
        document.Dispose();

        Assert.Equal(Arial.Length, Largest(result.Bytes).Length);
    }

    private static byte[] Shared(string content, string extra, Action<TestPdf> more, string pageExtra = "", string contents = "4 0 R") =>
        OptimizeKit.Build(content, "/Font <</F1 5 0 R>> " + extra, pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            more(pdf);
        }, pageExtra, contents: contents, shared: true);

    private static byte[] Trimmed(byte[] file, out OptimizeResult result)
    {
        using var document = PdfDocument.Open(file);
        result = new PdfOptimizer(document).Run(Subset);
        return Largest(result.Bytes);
    }

    [Fact]
    public void A_soft_mask_group_sharing_the_page_resources_keeps_the_glyphs()
    {
        byte[] file = Shared("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/ExtGState <</GS1 8 0 R>>", pdf =>
        {
            pdf.Obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceGray>> /Resources 12 0 R", "BT /F1 18 Tf 10 50 Td (Zed) Tj ET");
        });

        var font = Trimmed(file, out var result);

        Assert.True(Has(font, 'Z') && Has(font, 'H'));
        Assert.Contains(OptimizeText.LeftPartialFonts, result.Notes);
    }

    [Fact]
    public void A_hidden_appearance_state_sharing_the_page_resources_keeps_the_glyphs()
    {
        byte[] file = Shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", pdf =>
        {
            pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources 12 0 R", "BT /F1 12 Tf 2 2 Td (Q) Tj ET");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources 12 0 R", "");
        }, "/Annots [8 0 R]");

        Assert.True(Has(Trimmed(file, out _), 'Q'));
    }

    [Fact]
    public void An_appearance_without_resources_uses_the_page_fonts()
    {
        byte[] file = Shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", pdf =>
        {
            pdf.Obj(8, "<</Type /Annot /Subtype /FreeText /Rect [10 10 50 50] /AP <</N 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "BT /F1 12 Tf 2 2 Td (Q) Tj ET");
        }, "/Annots [8 0 R]");

        var font = Trimmed(file, out var result);

        Assert.True(Has(font, 'Q') && Has(font, 'H'));
        Assert.DoesNotContain(OptimizeText.LeftPartialFonts, result.Notes);
    }

    [Fact]
    public void A_page_stream_that_cannot_be_read_leaves_the_fonts_whole()
    {
        byte[] file = Shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", pdf => pdf.Stream(8, "/Filter /FlateDecode", "not deflate data"), contents: "[4 0 R 8 0 R]");

        Assert.Equal(Arial.Length, Trimmed(file, out var result).Length);
        Assert.Contains(OptimizeText.LeftPartialFonts, result.Notes);
    }

    [Fact]
    public void A_form_that_cannot_be_read_leaves_the_fonts_whole()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET /Fm0 Do", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Filter /FlateDecode /Resources <</Font <</F2 5 0 R>>>>", "not deflate data");
        });

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }

    // A page whose run ends at the operation limit shows nothing after it.
    private static string Spin(int times) => string.Concat(Enumerable.Repeat("/Fm0 Do\n", times));

    private static void Spinner(TestPdf pdf) =>
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", string.Concat(Enumerable.Repeat("q Q ", 50)));

    [Fact]
    public void A_page_run_cut_short_leaves_the_fonts_whole()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET\n" + Spin(100_000) + "BT /F1 18 Tf 10 50 Td (Zed) Tj ET", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            Spinner(pdf);
        });

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }

    [Fact]
    public void An_appearance_run_cut_short_leaves_the_fonts_whole()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            Spinner(pdf);
            pdf.Obj(9, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AP <</N 10 0 R>>>>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>>>",
                Spin(100_000) + "BT /F1 12 Tf 2 2 Td (Q) Tj ET");
        }, "/Annots [9 0 R]");

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }

    [Fact]
    public void A_glyph_procedure_without_resources_leaves_the_fonts_whole()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET BT /T3 10 Tf (a) Tj ET", "/Font <</F1 5 0 R /T3 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Obj(8, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 9 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1]>>");
            pdf.Stream(9, "", "1 0 d0 BT /F1 1 Tf (Z) Tj ET");
        });

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }

    [Fact]
    public void A_font_written_directly_in_a_graphics_state_blocks_the_shared_program()
    {
        byte[] file = OptimizeKit.Build("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</GS1 8 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
            pdf.Obj(8, $"<</Type /ExtGState /Font [<</Type /Font {Font()}>> 12]>>");
        });

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }

    [Fact]
    public void A_default_resources_font_blocks_the_shared_program()
    {
        byte[] file = OptimizeKit.Build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font " + Font() + ">>");
            Program(pdf);
        }, catalogExtra: $"/AcroForm <</Fields [] /DR <</Font <</Helv <</Type /Font {Font()}>>>>>>>>");

        Assert.Equal(Arial.Length, Trimmed(file, out _).Length);
    }
}
