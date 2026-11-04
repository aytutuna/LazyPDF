using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal sealed record ImageSeen(PdfMatrix Matrix, PdfRect Clip, double Alpha, int Width, int Height);

/// <summary>Pages with pictures and paths, and what the interpreter paints from them.</summary>
internal static class EditPaint
{
    /// <summary>An 8 by 6 pixel colour JPEG.</summary>
    public const string SampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z";

    public static byte[] Jpeg() => Convert.FromBase64String(SampleJpeg);

    /// <summary>A page with two pictures: the JPEG at 100 by 50 in a q, a 2 by 2 gray one at 80 by 80 in another.</summary>
    public static PdfEditSession Pictures(string extra = "")
    {
        byte[] file = EditKit.File("q 100 0 0 50 100 600 cm /Im1 Do Q\nq 80 0 0 80 300 600 cm /Im2 Do Q\n" + extra, more: pdf =>
        {
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", Jpeg());
            pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0]);
        }, resources: "/Font <</F1 5 0 R>> /XObject <</Im1 7 0 R /Im2 8 0 R>>");
        return PdfEditSession.Open(file);
    }

    public static List<ImageSeen> Images(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var seen = new List<ImageSeen>();
        new ContentInterpreter(document).Run(document.Pages[0], new ImageProbe(seen));
        return seen;
    }

    private sealed class ImageProbe(List<ImageSeen> seen) : ContentVisitor
    {
        public override void PaintImage(ContentContext context, ImageInfo image) =>
            seen.Add(new ImageSeen(image.Matrix, context.State.Clip, context.State.FillAlpha, image.Width, image.Height));
    }

    public sealed record PathSeen(PathInfo Path, RgbColor Fill, RgbColor Stroke, double LineWidth, double Alpha);

    public static List<PathSeen> Paths(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var seen = new List<PathSeen>();
        new ContentInterpreter(document).Run(document.Pages[0], new PathProbe(seen));
        return seen;
    }

    private sealed class PathProbe(List<PathSeen> seen) : ContentVisitor
    {
        public override void PaintPath(ContentContext context, PathInfo path)
        {
            var s = context.State;
            if (path.Fill || path.Stroke) seen.Add(new PathSeen(path, s.FillColor.Rgb, s.StrokeColor.Rgb, s.LineWidth, s.FillAlpha));
        }
    }
}
