using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class BackgroundTests
{
    private static readonly byte[] Jpeg = Convert.FromBase64String(StampKit.SampleJpeg);

    [Fact]
    public void AColourFillsThePageBehindTheContent()
    {
        var document = StampKit.Doc(1);
        new PdfStamper(document).AddBackground(new BackgroundSpec { Color = new StampColor(1, 1, 0.8) });
        var file = StampKit.Rewrite(document);

        using var reopened = PdfDocument.Open(file);
        var recorder = ContentTestPdf.Run(reopened);
        var (path, state) = Assert.Single(recorder.Paths, p => p.Path.Fill);
        Assert.True(path.Fill);
        Assert.Equal(new PdfRect(0, 0, 200, 300), path.Bounds);
        Assert.Equal([1, 1, 0.8], state.FillColor.Components);
        Assert.StartsWith("q\n", StampKit.Latin(reopened, 0));
        Assert.Contains("1", StampKit.PigText(file));
        var info = Assert.Single(new PdfStamper(reopened).List());
        Assert.Equal((StampKind.Background, true), (info.Kind, info.Behind));
    }

    [Fact]
    public void CoverFillsThePageAndClipsTheOverflow()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddJpeg(document, Jpeg)!;
        new PdfStamper(document).AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Cover });
        var placed = Assert.Single(ContentTestPdf.Run(document).Images);
        Assert.Equal(300, placed.Bounds.Height, 3);
        Assert.Equal(400, placed.Bounds.Width, 3);
        Assert.Equal(-100, placed.Bounds.Left, 3);
    }

    [Fact]
    public void ContainStaysInsideAndStretchChangesTheProportions()
    {
        var document = StampKit.Doc(2);
        var image = PdfImageWriter.AddJpeg(document, Jpeg)!;
        var stamper = new PdfStamper(document);
        stamper.AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Contain, Pages = [0] });
        stamper.AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Stretch, Pages = [1] });

        var contained = Assert.Single(ContentTestPdf.Run(document).Images).Bounds;
        Assert.Equal((200, 150, 0, 75), (contained.Width, contained.Height, contained.Left, contained.Bottom));
        var stretched = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[1], stretched);
        Assert.Equal(new PdfRect(0, 0, 200, 300), Assert.Single(stretched.Images).Bounds);
    }

    [Fact]
    public void ColourAndImageTogetherAndTranslucent()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddRgba(document, 2, 2, new byte[16]);
        new PdfStamper(document).AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.9), Image = image, Opacity = 0.5 });
        var recorder = ContentTestPdf.Run(document);
        Assert.Single(recorder.Paths, p => p.Path.Fill);
        Assert.Single(recorder.Images);
        var state = document.Dict(document.Dict(document.Pages[0].Resources, "ExtGState"), "LPS1_G")!;
        Assert.Equal(0.5, document.Number(state, "ca"));
        using var pig = PigDocument.Open(StampKit.Rewrite(document));
        Assert.Single(pig.GetPage(1).GetImages());
    }

    [Fact]
    public void ABackgroundNeedsAColourOrAnImage()
    {
        Assert.Throws<ArgumentException>(() => new PdfStamper(StampKit.Doc(1)).AddBackground(new BackgroundSpec()));
    }

    [Fact]
    public void ARotatedPageIsCoveredAsItIsShown()
    {
        var document = StampKit.Pages(("/Rotate 90", "BT /F1 12 Tf 50 50 Td (r) Tj ET"));
        var image = PdfImageWriter.AddJpeg(document, Jpeg)!;
        new PdfStamper(document).AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Contain });
        var placed = Assert.Single(ContentTestPdf.Run(document).Images);
        var shown = new PageGeometry(document.Pages[0]).ToDisplay(placed.Bounds);
        Assert.Equal(266.667, shown.Width, 3);
        Assert.Equal(200, shown.Height, 3);
        Assert.Equal(16.667, shown.X, 3);
    }
}
