using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeGrayTests
{
    private sealed class Fills : ContentVisitor
    {
        public readonly List<(RgbColor Fill, RgbColor Stroke)> Colors = [];

        public override void PaintPath(ContentContext context, PathInfo path) =>
            Colors.Add((context.State.FillColor.Rgb, context.State.StrokeColor.Rgb));
    }

    private static List<(RgbColor Fill, RgbColor Stroke)> Painted(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        var fills = new Fills();
        new ContentInterpreter(document).Run(document.Pages[0], fills);
        return fills.Colors;
    }

    private static readonly OptimizeOptions Gray = OptimizeKit.Off with { Grayscale = true };

    private static byte Luminance(RgbColor c) => (byte)Math.Round(0.299 * c.R + 0.587 * c.G + 0.114 * c.B);

    private static OptimizeResult Run(byte[] file, IImageCodec? codec = null)
    {
        using var document = PdfDocument.Open(file);
        return new PdfOptimizer(document, codec).Run(Gray);
    }

    [Fact]
    public void ColourOperatorsBecomeGrayWithTheSameBrightness()
    {
        const string content = "1 0 0 rg 0 0 50 50 re f 0 0 1 RG 0.2 0.4 0.6 0.1 k 0 0 20 20 re B /Cs0 cs 0.5 0.25 0.75 sc 0 0 9 9 re f /DeviceCMYK cs 0.1 0.2 0.3 0.4 sc 0 0 5 5 re f";
        byte[] file = OptimizeKit.Build(content, "/ColorSpace <</Cs0 [/ICCBased 5 0 R]>>", pdf => pdf.Stream(5, "/N 3", "profile"));
        var before = Painted(file);
        var result = Run(file);
        var after = Painted(result.Bytes);
        Assert.Equal(before.Count, after.Count);
        for (int i = 0; i < before.Count; i++)
        {
            Assert.InRange(after[i].Fill.R - Luminance(before[i].Fill), -1, 1);
            Assert.Equal(after[i].Fill.R, after[i].Fill.G);
            Assert.Equal(after[i].Fill.G, after[i].Fill.B);
            Assert.InRange(after[i].Stroke.R - Luminance(before[i].Stroke), -1, 1);
            Assert.Equal(after[i].Stroke.R, after[i].Stroke.B);
        }
        using var document = PdfDocument.Open(result.Bytes);
        var operators = ContentParser.Parse(document.Pages[0].Contents()).Select(o => o.Operator).ToList();
        Assert.DoesNotContain("rg", operators);
        Assert.DoesNotContain("RG", operators);
        Assert.DoesNotContain("k", operators);
    }

    [Fact]
    public void OperatorsInAFormFollowTheNumberOfOperands()
    {
        byte[] file = OptimizeKit.Build("q 1 0 0 rg /Fm0 Do Q", "/XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0 1 0 sc 0 0 10 10 re f 0 0 0 1 k 0 0 5 5 re f"));
        var result = Run(file);
        using var document = PdfDocument.Open(result.Bytes);
        var form = (PdfStream)document.Resolve(document.Dict(document.Pages[0].Resources, "XObject")!["Fm0"])!;
        var operations = ContentParser.Parse(document.Data(form));
        Assert.All(operations.Where(o => o.Operator is "sc" or "g"), o => Assert.Single(o.Operands));
        Assert.Contains(operations, o => o.Operator == "g" && Math.Abs(o.Number(0)!.Value - 0.587) < 0.001);
        Assert.Equal(2, result.Steps.Single(s => s.Kind == OptimizeStepKind.Grayscale).Count);
    }

    [Fact]
    public void ShadingsAndSpotColoursAreLeftAndReported()
    {
        const string resources = "/Shading <</Sh0 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1>>>>>> " +
            "/ColorSpace <</Sp0 [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>]>>";
        byte[] file = OptimizeKit.Build("/Sh0 sh /Sp0 cs 1 scn 0 0 10 10 re f", resources);
        var result = Run(file);
        Assert.Contains(OptimizeText.LeftColor, result.Notes);
        using var document = PdfDocument.Open(result.Bytes);
        var operators = ContentParser.Parse(document.Pages[0].Contents()).Select(o => o.Operator).ToList();
        Assert.Contains("sh", operators);
        Assert.Contains("scn", operators);
        Assert.Equal("Sp0", ((PdfName)ContentParser.Parse(document.Pages[0].Contents()).First(o => o.Operator == "cs").Operands[0]).Value);
    }

    [Fact]
    public void ImagesAreConvertedAndKeepTheirMask()
    {
        const int w = 8, h = 8;
        var rgb = OptimizeKit.Gradient(w, h, 3);
        const string dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode";
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, dictionary + " /ColorSpace /DeviceRGB /SMask 6 0 R", TestPdf.Deflate(rgb));
            pdf.Stream(6, dictionary + " /ColorSpace /DeviceGray", TestPdf.Deflate(OptimizeKit.Gradient(w, h, 1)));
        });
        var result = Run(file);
        using var after = PdfDocument.Open(result.Bytes);
        var image = OptimizeKit.Image(after);
        Assert.Equal("DeviceGray", after.Name(image.Dictionary, "ColorSpace"));
        Assert.NotNull(after.Stream(image.Dictionary, "SMask"));
        var gray = after.Data(image);
        Assert.Equal(w * h, gray.Length);
        for (int i = 0; i < gray.Length; i++) Assert.Equal(ImageKit.Luminance(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2]), gray[i]);
    }

    [Fact]
    public void JpegBecomesGrayThroughTheCodec()
    {
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", OptimizeKit.TinyJpeg));
        var codec = new OptimizeFakeCodec();
        var result = Run(file, codec);
        var written = codec.LastEncoded!;
        for (int i = 0; i < written.Width * written.Height; i++) Assert.Equal(written.Rgba[4 * i], written.Rgba[4 * i + 1]);
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal("DCTDecode", after.Name(OptimizeKit.Image(after).Dictionary, "Filter"));
        Assert.DoesNotContain(OptimizeText.NeedsCodec, result.Notes);
    }

    [Fact]
    public void JpegWhoseHeaderReadsZeroHeightIsLeft()
    {
        var jpeg = (byte[])OptimizeKit.TinyJpeg.Clone();
        int at = jpeg.AsSpan().IndexOf(new byte[] { 0xFF, 0xC0 });
        jpeg[at + 5] = 0;
        jpeg[at + 6] = 0;
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg));
        var codec = new OptimizeFakeCodec();
        var result = Run(file, codec);
        Assert.Null(codec.LastEncoded);
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(jpeg, after.RawData(OptimizeKit.Image(after)));
    }

    [Fact]
    public void JpegWithoutACodecStaysInColourAndSaysSo()
    {
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", OptimizeKit.TinyJpeg));
        var result = Run(file);
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal("DeviceRGB", after.Name(OptimizeKit.Image(after).Dictionary, "ColorSpace"));
        Assert.Contains(OptimizeText.NeedsCodec, result.Notes);
        Assert.Contains(OptimizeText.LeftColor, result.Notes);
    }

    [Fact]
    public void PdfPigStillReadsTheTextOfAGrayFile()
    {
        byte[] file = OptimizeKit.Build("1 0 0 rg BT /F1 12 Tf 10 100 Td (red words) Tj ET", "/Font <</F1 5 0 R>>", pdf =>
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"));
        var result = Run(file);
        Assert.Equal("red words", OptimizeKit.PigText(result.Bytes).Trim());
    }

    private static IReadOnlyList<ContentOperation> Operators(PdfDocument document, PdfStream stream) => ContentParser.Parse(document.Data(stream));

    [Fact]
    public void AnIndexedImagesMatteIsLookedUpInThePalette()
    {
        const string dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode";
        byte[] file = OptimizeKit.Build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, dictionary + " /ColorSpace [/Indexed /DeviceRGB 1 <FFFFFF000000>] /SMask 6 0 R", TestPdf.Deflate(new byte[64]));
            pdf.Stream(6, dictionary + " /ColorSpace /DeviceGray /Matte [1]", TestPdf.Deflate(OptimizeKit.Gradient(8, 8, 1)));
        });
        using var after = PdfDocument.Open(Run(file).Bytes);

        var matte = after.Array(after.Stream(OptimizeKit.Image(after).Dictionary, "SMask")!.Dictionary, "Matte")!;
        Assert.Equal(0, ((PdfNumber)matte.Items.Single()).Value);
    }

    [Fact]
    public void ColourInASpaceThatCannotBeLookedUpStaysAndIsReported()
    {
        byte[] file = OptimizeKit.Build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "/Cs1 cs 1 0 0 sc 0 0 5 5 re f"));
        var result = Run(file);

        Assert.Contains(OptimizeText.LeftColor, result.Notes);
    }

    [Fact]
    public void AColourSpaceNamedInOneStreamAndSetInTheNextIsLeftAlone()
    {
        byte[] file = OptimizeKit.Build("/DeviceRGB cs 1 0 0", contents: "[4 0 R 5 0 R]", more: pdf => pdf.Stream(5, "", "sc 0 0 5 5 re f"));
        var result = Run(file);

        using var document = PdfDocument.Open(result.Bytes);
        var all = ContentParser.Parse(document.Pages[0].Contents());
        Assert.Equal("DeviceRGB", ((PdfName)all.Single(o => o.Operator == "cs").Operands[0]).Value);
        Assert.Equal(3, all.Single(o => o.Operator == "sc").Operands.Count);
        Assert.Contains(OptimizeText.LeftColor, result.Notes);
    }

    [Fact]
    public void AFormInheritingALabSpaceKeepsItsOperands()
    {
        byte[] file = OptimizeKit.Build("/L cs /Fm0 Do", "/ColorSpace <</L [/Lab <</WhitePoint [0.95 1 1.09]>>]>> /XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "50 20 30 sc 0 0 5 5 re f"));
        var result = Run(file);

        using var document = PdfDocument.Open(result.Bytes);
        var form = (PdfStream)document.Resolve(document.Dict(document.Pages[0].Resources, "XObject")!["Fm0"])!;
        Assert.Equal(3, Operators(document, form).Single(o => o.Operator == "sc").Operands.Count);
    }

    [Fact]
    public void EveryInheritedColourInAFormIsConverted()
    {
        byte[] file = OptimizeKit.Build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", pdf =>
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "1 0 0 sc 0 0 5 5 re f 0 1 0 sc 5 5 5 5 re f"));
        var result = Run(file);

        using var document = PdfDocument.Open(result.Bytes);
        var form = (PdfStream)document.Resolve(document.Dict(document.Pages[0].Resources, "XObject")!["Fm0"])!;
        Assert.All(Operators(document, form).Where(o => o.Operator is "sc" or "g"), o => Assert.Single(o.Operands));
    }

    [Fact]
    public void AnRgbCallerAndALabSomewhereElseStillAgreeWithTheForm()
    {
        const string resources = "/ColorSpace <</Cs0 [/ICCBased 6 0 R] /L [/Lab <</WhitePoint [0.95 1 1.09]>>]>> /XObject <</Fm0 5 0 R>>";
        byte[] file = OptimizeKit.Build("/Cs0 cs /Fm0 Do", resources, pdf =>
        {
            pdf.Stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0.2 0.4 0.6 sc 0 0 5 5 re f");
            pdf.Stream(6, "/N 3", "profile");
        });
        var result = Run(file);

        using var document = PdfDocument.Open(result.Bytes);
        var form = (PdfStream)document.Resolve(document.Dict(document.Pages[0].Resources, "XObject")!["Fm0"])!;
        Assert.Equal("DeviceGray", ((PdfName)ContentParser.Parse(document.Pages[0].Contents()).Single(o => o.Operator == "cs").Operands[0]).Value);
        Assert.Single(Operators(document, form).Single(o => o.Operator is "sc" or "g").Operands);
    }
}
