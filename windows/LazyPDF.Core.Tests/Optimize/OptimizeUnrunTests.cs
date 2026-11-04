using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeUnrunTests
{
    private static readonly OptimizeOptions Downsample = OptimizeKit.Off with { ImageDpi = 72, ImageDpiAbove = 100 };

    private const string Type3 = "/Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1]";
    private const string Tiling = "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Im0 5 0 R>>>>";

    private static void Picture(TestPdf pdf) =>
        pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 200 /Height 200 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(OptimizeKit.Gradient(200, 200, 3)));

    private static OptimizeResult Run(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        return new PdfOptimizer(document).Run(Downsample);
    }

    private static long WidthOf(OptimizeResult result)
    {
        using var after = PdfDocument.Open(result.Bytes);
        var image = after.ObjectNumbers.Select(n => after.Get(n)).OfType<PdfStream>().Single(x => OptimizeKit.IsImage(after, x));
        return after.Integer(image.Dictionary, "Width") ?? 0;
    }

    private static void HiddenState(TestPdf pdf, string onEntries, string onContent)
    {
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>");
        pdf.Stream(9, onEntries, onContent);
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "");
    }

    [Fact]
    public void A_hidden_state_with_no_subtype_counts_as_a_form_that_never_ran()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            HiddenState(pdf, "/BBox [0 0 40 40] /Resources 12 0 R", "q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, pageExtra: "/Annots [8 0 R]", shared: true);
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_hidden_state_without_resources_that_names_an_image_leaves_the_image_whole()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            HiddenState(pdf, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, pageExtra: "/Annots [8 0 R]");
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_hidden_state_without_resources_that_only_draws_a_path_changes_nothing()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            Picture(pdf);
            HiddenState(pdf, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 10 10 re f");
        }, pageExtra: "/Annots [8 0 R]");

        Assert.True(WidthOf(Run(file)) < 200);
    }

    [Fact]
    public void A_bitmap_type_3_font_without_resources_does_not_stop_the_downsampling()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(6, "<<" + Type3 + ">>");
            pdf.Stream(7, "", "1 0 0 0 1 1 d1 0 0 1 1 re f");
        });

        Assert.True(WidthOf(Run(file)) < 200);
    }

    [Fact]
    public void A_type_3_glyph_without_resources_that_paints_an_image_leaves_it_whole()
    {
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(6, "<<" + Type3 + ">>");
            pdf.Stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q");
        });
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_file_without_images_never_says_images_were_left()
    {
        byte[] file = OptimizeKit.Build("BT /T3 10 Tf (a) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<<" + Type3 + ">>");
            pdf.Stream(7, "", "1 0 d0 BT /F1 1 Tf (Z) Tj ET");
        });

        Assert.DoesNotContain(OptimizeText.LeftPartialImages, Run(file).Notes);
    }

    [Fact]
    public void An_unseen_image_that_is_small_enough_is_not_reported()
    {
        byte[] file = OptimizeKit.Build("q 200 0 0 200 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(6, "<<" + Type3 + " /Resources 12 0 R>>");
            pdf.Stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q");
        }, shared: true);
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.DoesNotContain(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_form_also_used_as_a_soft_mask_group_keeps_the_pixels_it_shows()
    {
        byte[] file = OptimizeKit.Build("/GS1 gs q 50 0 0 50 0 0 cm /G Do Q", "/XObject <</G 9 0 R>> /ExtGState <</GS1 8 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Group <</S /Transparency /CS /DeviceRGB>> /Resources <</XObject <</Im0 5 0 R>>>>", "q 1 0 0 1 0 0 cm /Im0 Do Q");
        });
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    private static byte[] Tiled(string content, bool twice)
    {
        const string form = "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</Pattern <</P 9 0 R>>>>";
        return OptimizeKit.Build(content, twice ? "/XObject <</Fm0 6 0 R /Fm1 8 0 R>>" : "/XObject <</Fm0 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Stream(6, form, "/Pattern cs /P scn 0 0 100 100 re f");
            if (twice) pdf.Stream(8, form, "/Pattern cs /P scn 0 0 100 100 re f");
            pdf.Stream(9, Tiling, "q 10 0 0 10 0 0 cm /Im0 Do Q");
        });
    }

    [Fact]
    public void A_pattern_painted_at_one_scale_is_measured()
    {
        Assert.True(WidthOf(Run(Tiled("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q", false))) < 200);
    }

    [Fact]
    public void A_pattern_painted_by_forms_at_two_scales_leaves_its_image_whole()
    {
        var result = Run(Tiled("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q q 10 0 0 10 0 0 cm /Fm1 Do Q", true));

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }

    [Fact]
    public void A_pattern_a_glyph_procedure_may_paint_elsewhere_leaves_its_image_whole()
    {
        byte[] file = OptimizeKit.Build("/Pattern cs /P scn 0 0 100 100 re f", "/Pattern <</P 9 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            Picture(pdf);
            pdf.Obj(6, "<<" + Type3 + " /Resources <</Pattern <</P 9 0 R>>>>>>");
            pdf.Stream(7, "", "1 0 d0 /Pattern cs /P scn 0 0 1 1 re f");
            pdf.Stream(9, Tiling, "q 10 0 0 10 0 0 cm /Im0 Do Q");
        });
        var result = Run(file);

        Assert.Equal(200, WidthOf(result));
        Assert.Contains(OptimizeText.LeftPartialImages, result.Notes);
    }
}
