using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeUnseenImageTests
{
    private static readonly OptimizeOptions Downsample = OptimizeKit.Off with { ImageDpi = 72, ImageDpiAbove = 100 };

    private static string Rgb(int size, string extra = "") =>
        $"/Type /XObject /Subtype /Image /Width {size} /Height {size} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode {extra}";

    private static long WidthAfter(byte[] file, OptimizeOptions options)
    {
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(options);
        using var after = PdfDocument.Open(result.Bytes);
        return after.Integer(OptimizeKit.Image(after).Dictionary, "Width") ?? 0;
    }

    [Fact]
    public void A_page_unit_scales_the_placed_size()
    {
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>",
            pdf => pdf.Stream(5, Rgb(800), TestPdf.Deflate(OptimizeKit.Gradient(800, 800, 3))), pageExtra: "/UserUnit 10");

        // 800 pixels over 800 points are 72 dpi, which is what is asked for.
        Assert.Equal(800, WidthAfter(file, Downsample));
    }

    [Fact]
    public void An_image_also_painted_large_in_a_soft_mask_group_keeps_its_pixels()
    {
        byte[] file = OptimizeKit.Build("/GS1 gs q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>> /ExtGState <</GS1 8 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(200), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));
            pdf.Obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceRGB>> /Resources <</XObject <</Im0 5 0 R>>>>",
                "q 200 0 0 200 0 0 cm /Im0 Do Q");
        });

        Assert.Equal(200, WidthAfter(file, Downsample));
    }

    [Fact]
    public void An_image_reached_by_a_type_3_glyph_through_an_indirect_table_is_left()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(200), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));
            pdf.Obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources <</XObject 8 0 R>>>>");
            pdf.Stream(7, "", "1 0 d0 q 1 0 0 1 0 0 cm /Im0 Do Q");
            pdf.Obj(8, "<</Im0 5 0 R>>");
        });

        Assert.Equal(200, WidthAfter(file, Downsample));
    }

    [Fact]
    public void A_soft_mask_that_declares_a_huge_size_is_left_and_the_image_with_it()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(200, "/SMask 6 0 R"), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 60000 /Height 60000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(new byte[16]));
        });

        Assert.Equal(200, WidthAfter(file, Downsample));
    }

    [Fact]
    public void An_image_whose_mask_has_a_matte_is_not_resized()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(200, "/SMask 6 0 R"), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 200 /Height 200 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [0 0 0] /Filter /FlateDecode",
                TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 1)));
        });

        Assert.Equal(200, WidthAfter(file, Downsample));
    }

    [Fact]
    public void A_two_colour_image_with_a_matte_stays_eight_bit()
    {
        var black = new byte[20 * 20 * 3];
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(20, "/SMask 6 0 R"), TestPdf.Deflate(black));
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 20 /Height 20 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [0 0 0] /Filter /FlateDecode",
                TestPdf.Deflate(new byte[400]));
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { BilevelTolerance = 8 });

        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal("DeviceRGB", after.Name(OptimizeKit.Image(after).Dictionary, "ColorSpace"));
    }

    private static void Picture(TestPdf pdf) => pdf.Stream(5, Rgb(200), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));

    private static OptimizeResult Run(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        return new PdfOptimizer(document).Run(Downsample);
    }

    private static long WidthOf(OptimizeResult result)
    {
        using var after = PdfDocument.Open(result.Bytes);
        return after.Integer(OptimizeKit.Image(after).Dictionary, "Width") ?? 0;
    }

    [Fact]
    public void A_soft_mask_group_sharing_the_page_resources_leaves_the_image_alone()
    {
        byte[] file = OptimizeKit.Build("/GS1 gs q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>> /ExtGState <</GS1 8 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceRGB>> /Resources 12 0 R", "q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, shared: true);
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_type_3_font_sharing_the_page_resources_leaves_the_image_alone()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources 12 0 R>>");
            pdf.Stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, shared: true);

        Assert.Equal(200, WidthOf(Run(file)));
    }

    [Fact]
    public void An_appearance_without_resources_is_measured_with_the_page_resources()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 200 200] /AP <</N 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200]", "q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, pageExtra: "/Annots [8 0 R]");

        Assert.Equal(200, WidthOf(Run(file)));
    }

    [Fact]
    public void A_page_stream_that_cannot_be_read_leaves_the_image_alone_and_says_so()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Stream(8, "/Filter /FlateDecode", "not deflate data");
        }, contents: "[4 0 R 8 0 R]");
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void An_empty_appearance_state_without_resources_does_not_stop_the_downsampling()
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Yes /AP <</N <</Yes 9 0 R /Off 10 0 R>>>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 40 40 re S");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "");
        }, pageExtra: "/Annots [8 0 R]");
        var result = Run(file);

        Assert.Equal(100, WidthOf(result));
        Assert.DoesNotContain(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Theory]
    [InlineData(134217728, "DeviceGray", 16)]
    [InlineData(100000000, "DeviceRGB", 8)]
    public void A_soft_mask_with_a_huge_row_is_left_as_it_is(int width, string space, int bits)
    {
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, Rgb(200, "/SMask 6 0 R"), TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));
            pdf.Stream(6, $"/Type /XObject /Subtype /Image /Width {width} /Height 1 /ColorSpace /{space} /BitsPerComponent {bits} /Filter /FlateDecode", TestPdf.Deflate(new byte[16]));
        });

        Assert.Equal(100, WidthOf(Run(file)));
    }
}
