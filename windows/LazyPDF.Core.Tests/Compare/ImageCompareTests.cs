using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class ImageCompareTests
{
    private static readonly CompareLine[] Text = [new("Some text on a page with pictures")];

    private readonly record struct Pic(double X, double Y, double W, double H, string Pixels);

    private static readonly Pic Logo = new(100, 300, 80, 60, "00FF00FF");

    /// <summary>A page with the given pictures: gray 2 by 2 images, or the real JPEG when the pixels read "jpeg".</summary>
    private static PdfDocument WithImages(params Pic[] images)
    {
        var bytes = Bytes([Text], more: (pdf, first) =>
        {
            for (int i = 0; i < images.Length; i++)
            {
                if (images[i].Pixels == "jpeg") pdf.Stream(first + i, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", Convert.FromBase64String(SampleJpeg));
                else pdf.Stream(first + i, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", images[i].Pixels + ">");
            }
        });
        string xobjects = string.Join(" ", images.Select((_, i) => $"/Im{i} {8 + i} 0 R"));
        string draw = string.Concat(images.Select((m, i) => $"q {m.W} 0 0 {m.H} {m.X} {m.Y} cm /Im{i} Do Q "));
        string file = TestPdf.Text(bytes)
            .Replace("/Resources <</Font", $"/Resources <</XObject <<{xobjects}>> /Font")
            .Replace("Tj ET\n", $"Tj ET\n{draw}");
        return Open(TestPdf.Latin(file));
    }

    private static ComparisonResult Run(Pic[] a, Pic[] b)
    {
        using var before = WithImages(a);
        using var after = WithImages(b);
        return PdfComparer.Compare(before, after);
    }

    [Fact]
    public void SameImageSamePlaceIsNoChange() => Assert.True(Run([Logo], [Logo]).IsIdentical);

    [Fact]
    public void SameJpegSamePlaceIsNoChange()
    {
        var photo = new Pic(100, 300, 80, 60, "jpeg");
        Assert.True(Run([photo], [photo]).IsIdentical);
    }

    [Fact]
    public void JpegAgainstAGrayImageIsAReplacement()
    {
        var change = Assert.Single(Run([new Pic(100, 300, 80, 60, "jpeg")], [Logo]).Changes);
        Assert.Equal(CompareText.ImageReplaced, change.Detail);
    }

    [Fact]
    public void MovedImageIsOneChange()
    {
        var change = Assert.Single(Run([Logo], [Logo with { X = 300, Y = 400 }]).Changes);
        Assert.Equal((ChangeKind.Changed, ChangeArea.Image), (change.Kind, change.Area));
        Assert.Equal(CompareText.ImageMoved, change.Detail);
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Left, 99, 101);
        Assert.InRange(Assert.Single(change.NewQuads).Bounds.Left, 299, 301);
    }

    [Fact]
    public void ReplacedImageAtTheSamePlaceIsOneChange()
    {
        var change = Assert.Single(Run([Logo], [Logo with { Pixels = "FF00FF00" }]).Changes);
        Assert.Equal(CompareText.ImageReplaced, change.Detail);
    }

    [Fact]
    public void AddedAndRemovedImages()
    {
        var added = Assert.Single(Run([], [Logo]).Changes);
        Assert.Equal((ChangeKind.Added, ChangeArea.Image), (added.Kind, added.Area));
        Assert.Empty(added.OldQuads);
        var removed = Assert.Single(Run([Logo], []).Changes);
        Assert.Equal(ChangeKind.Removed, removed.Kind);
        Assert.Empty(removed.NewQuads);
    }

    [Fact]
    public void EqualPicturesAreMatchedOneToOne()
    {
        var result = Run([Logo, Logo], [Logo]);
        Assert.Equal(ChangeKind.Removed, Assert.Single(result.Changes).Kind);
    }

    [Fact]
    public void PictureOnlyPagesArePairedByTheirPictures()
    {
        static byte[] Make(string first, string second)
        {
            var pdf = new TestPdf();
            pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
            pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>");
            pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</I 6 0 R>>>>>>");
            pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</I 7 0 R>>>>>>");
            pdf.Stream(5, "", "q 200 0 0 200 0 0 cm /I Do Q");
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", first + ">");
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", second + ">");
            return pdf.Finish();
        }
        using var a = Open(Make("00112233", "FF00FF00"));
        using var b = Open(Make("44556677", "FF00FF00"));
        var result = PdfComparer.Compare(a, b);
        Assert.Equal([0, 1], result.Pages.Select(p => p.NewIndex));
        Assert.All(result.Pages, p => Assert.False(p.IsAdded || p.IsRemoved));
        var change = Assert.Single(result.Changes);
        Assert.Equal((ChangeArea.Image, 0), (change.Area, change.NewPage));
    }
}
