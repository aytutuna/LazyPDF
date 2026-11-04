using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class StampAndMarkTests
{
    private static (PdfDocument Document, PdfAnnotationWriter Writer, PdfPage Page) Start(IFontSource? fonts = null)
    {
        var document = Blank();
        return (document, new PdfAnnotationWriter(document, fonts), document.Pages[0]);
    }

    private static Recorder Draw(PdfDocument document, PdfAnnotation annotation)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(Normal(document, annotation), recorder);
        return recorder;
    }

    [Fact]
    public void EveryStandardStampSaysItsWordsInsideItsBox()
    {
        var (document, writer, page) = Start();
        foreach (string name in AnnotationText.StandardStamps)
        {
            var stamp = writer.AddStamp(page, new PdfRect(100, 600, 300, 660), name);
            var recorder = Draw(document, stamp);
            Assert.Equal(AnnotationText.StampLabel(name).Replace(" ", ""), recorder.Text.Replace(" ", ""));
            Assert.All(recorder.Glyphs, g => Assert.True(g.Bounds.Left >= 0 && g.Bounds.Right <= 200 && g.Bounds.Top <= 60));
            Assert.Equal(name, stamp.IconName);
        }
        Reopen(document);
    }

    [Fact]
    public void LongStampWordsShrinkToFit()
    {
        var (document, writer, page) = Start();
        var stamp = writer.AddStamp(page, new PdfRect(100, 600, 160, 640), "NotForPublicRelease");
        var glyphs = Draw(document, stamp).Glyphs;
        Assert.True(glyphs[^1].Bounds.Right <= 60);
        Assert.True(glyphs[0].Bounds.Height < 10);
    }

    [Fact]
    public void CustomStampMayBeTurkish()
    {
        var (document, writer, page) = Start(new ArialSource());
        var stamp = writer.AddStamp(page, new PdfRect(100, 600, 360, 660), "ONAYLANDI ŞİMDİ", color: [0, 0.4, 0]);
        Assert.Equal("ONAYLANDI ŞİMDİ", Draw(document, stamp).Text);
        Assert.Equal([0d, 0.4, 0], stamp.Color);
    }

    [Fact]
    public void ImageStampPaintsItsPicture()
    {
        var (document, writer, page) = Start();
        byte[] rgba = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 255];
        var stamp = writer.AddImageStamp(page, new PdfRect(100, 600, 180, 660), 2, 2, rgba);
        var image = Draw(document, stamp).Images.Single();
        Assert.Equal((2, 2), (image.Width, image.Height));
        Assert.Equal(80, image.Bounds.Width, 3);
        Assert.NotNull(document.Stream(image.Dictionary, "SMask"));

        var moved = writer.Resize(stamp, new PdfRect(100, 600, 260, 720));
        Assert.Equal(160, moved.Rect.Width);
        Assert.Equal(80, Draw(document, moved).Images.Single().Bounds.Width, 3);
        Reopen(document);
    }

    [Fact]
    public void OpacityAndColorKeepTheArtworkOfAnImageStamp()
    {
        var (document, writer, page) = Start();
        byte[] rgba = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 255];
        var stamp = writer.AddImageStamp(page, new PdfRect(100, 600, 180, 660), 2, 2, rgba);
        var faded = writer.SetColor(writer.SetOpacity(stamp, 0.5), [1, 0, 0]);
        Assert.Single(Draw(document, faded).Images);
    }

    [Fact]
    public void JpegStampNeedsAReadableJpeg()
    {
        var (_, writer, page) = Start();
        Assert.Throws<ArgumentException>(() => writer.AddJpegStamp(page, new PdfRect(1, 1, 50, 50), [1, 2, 3]));
        Assert.Throws<ArgumentException>(() => writer.AddImageStamp(page, new PdfRect(1, 1, 50, 50), 2, 2, [1, 2, 3]));
    }

    [Fact]
    public void CaretIsAFilledWedge()
    {
        var (document, writer, page) = Start();
        var caret = writer.AddCaret(page, new PdfRect(100, 600, 116, 616), new AnnotationInfo("A", "insert here"));
        Assert.Equal("P", document.Name(caret.Dictionary, "Sy"));
        var path = Draw(document, caret).Paths.Single().Path;
        Assert.True(path.Fill);
        Assert.Equal(16, path.Bounds.Width, 0.01);
    }

    [Fact]
    public void AttachedFileCanBeListedAndExtracted()
    {
        var (document, writer, page) = Start();
        byte[] data = [.. Enumerable.Range(0, 500).Select(i => (byte)(i % 7))];
        var clip = writer.AddFileAttachment(page, new PdfRect(100, 700, 116, 716), "notes.bin", data, new AnnotationInfo("A", "see file"), "Paperclip", "application/octet-stream");
        Assert.Equal("Paperclip", clip.IconName);
        var reopened = Reopen(document);
        var attachment = Assert.Single(PdfAttachments.List(reopened));
        Assert.Equal("notes.bin", attachment.FileName);
        Assert.Equal(0, attachment.PageIndex);
        Assert.Equal(data, PdfAttachments.Extract(reopened, attachment));
        Assert.Contains("S", Operators(Appearance(document, clip)));
    }

    [Fact]
    public void RedactIsOnlyAMark()
    {
        var (document, writer, page) = Start();
        var mark = writer.AddRedact(page, [MarkupQuad.FromRect(new PdfRect(100, 600, 200, 614))], new AnnotationInfo("A"), [0, 0, 0], "REDACTED");
        Assert.Equal(AnnotationType.Redact, mark.Type);
        Assert.Equal([0d, 0d, 0d], mark.InteriorColor);
        Assert.Equal("REDACTED", PdfText.Read(document, mark.Dictionary, "OverlayText"));
        var path = Draw(document, mark).Paths.Single().Path;
        Assert.True(path.Stroke && !path.Fill);
        Assert.Throws<ArgumentException>(() => writer.AddRedact(page, []));
    }

    [Fact]
    public void LinkWithABorderGetsAnAppearanceAndOneWithoutDoesNot()
    {
        var (document, writer, page) = Start();
        var bordered = writer.AddLink(page, new PdfRect(100, 600, 200, 620), new UriAction("https://example.com"), new AnnotationStyle([0, 0, 1], 2));
        var plain = writer.AddLink(page, new PdfRect(100, 500, 200, 520), new PdfDestination(1, DestinationFit.Fit));
        Assert.True(bordered.HasAppearance);
        Assert.False(plain.HasAppearance);
        Assert.Equal(new PdfRect(1, 1, 99, 19), Draw(document, bordered).Paths.Single().Path.Bounds);
        var links = PdfLinks.Read(Reopen(document), document.Pages[0]);
        Assert.Equal(2, links.Count);
        Assert.Equal("https://example.com", links[0].Uri);
        Assert.Equal(1, links[1].Destination!.PageIndex);
    }

    [Fact]
    public void PdfPigSeesTheStampAndTheNote()
    {
        var (document, writer, page) = Start();
        writer.AddStamp(page, new PdfRect(100, 600, 300, 660), "Approved");
        writer.AddNote(page, new PdfRect(10, 700, 30, 720), new AnnotationInfo("A", "note"));
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        var types = pig.GetPage(1).GetAnnotations().Select(a => a.Type).ToList();
        Assert.Contains(UglyToad.PdfPig.Annotations.AnnotationType.Stamp, types);
        Assert.Contains(UglyToad.PdfPig.Annotations.AnnotationType.Text, types);
    }
}
