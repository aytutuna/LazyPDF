using System.Globalization;
using System.Windows;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.FillSign;

/// <summary>Where a signature or a line of text goes on a page, and putting it there. Boxes are in page space, y down.</summary>
internal static class FillSignPlacement
{
    public const double SignatureWidth = 150;
    public const double InitialsWidth = 60;

    /// <summary>A box of the given width centred on the click, kept on the page.</summary>
    public static DisplayRect Around(Point click, double width, double aspect, Size page)
    {
        double w = Math.Min(width, page.Width), h = w / aspect;
        return new(Math.Clamp(click.X - w / 2, 0, page.Width - w), Math.Clamp(click.Y - h / 2, 0, Math.Max(0, page.Height - h)), w, h);
    }

    /// <summary>The largest box with the picture's proportions that fits the drag from one corner to the other.</summary>
    public static DisplayRect FromDrag(Point from, Point to, double aspect, Size page)
    {
        double w = Math.Abs(to.X - from.X), h = Math.Abs(to.Y - from.Y);
        if (w < h * aspect) h = w / aspect;
        else w = h * aspect;
        double x = to.X < from.X ? from.X - w : from.X, y = to.Y < from.Y ? from.Y - h : from.Y;
        return new(Math.Clamp(x, 0, Math.Max(0, page.Width - w)), Math.Clamp(y, 0, Math.Max(0, page.Height - h)), w, h);
    }

    /// <summary>Why the file may not be added to; null when it may.</summary>
    public static Problem? Refusal(PdfDocument document) =>
        !PdfAnnotations.CanAnnotate(document)
            ? new Problem(Loc.T("This file cannot be changed"), Loc.T("Its permissions do not allow it. Open it with the owner password."))
            : null;

    /// <summary>What adding to the file does to its signatures; null when it has none.</summary>
    public static string? Caution(PdfDocument document) =>
        document.IsSigned ? Loc.T("This file is signed, so changing it breaks the signatures.") : null;

    public static bool PlaceImage(DocumentTab tab, int page, DisplayRect box, PdfRgbaImage image, DateTimeOffset now)
    {
        AddImage(tab.Document, page, box, image, null, now);
        return tab.Commit(Loc.T("Place signature"));
    }

    /// <summary>A picture stamp in the box, turned to stand upright on a turned page. The caller commits.</summary>
    public static PdfAnnotation AddImage(PdfDocument document, int page, DisplayRect box, PdfRgbaImage image, string? author, DateTimeOffset now)
    {
        var target = document.Pages[page];
        var rect = new PageGeometry(target).ToUser(box);
        var stamp = new PdfAnnotationWriter(document).AddImageStamp(target, AsShown(rect, box), image.Width, image.Height, image.Rgba, new AnnotationInfo(author, Date: now));
        TurnToPage(document, stamp, rect, target.Rotate);
        return stamp;
    }

    /// <summary>One or more lines of text with its left edge at the click, centred on it vertically.</summary>
    public static bool PlaceText(DocumentTab tab, IFontSource fonts, int page, Point click, string text, double size, DateTimeOffset now)
    {
        var document = tab.Document;
        var pdfPage = document.Pages[page];
        var geometry = new PageGeometry(pdfPage);
        var (width, height) = Measure(text, size);
        var box = new DisplayRect(
            Math.Clamp(click.X, 0, Math.Max(0, geometry.Width - width)),
            Math.Clamp(click.Y - height / 2, 0, Math.Max(0, geometry.Height - height)),
            Math.Min(width, geometry.Width), Math.Min(height, geometry.Height));
        var rect = geometry.ToUser(box);
        var note = new PdfAnnotationWriter(document, fonts).AddFreeText(pdfPage, AsShown(rect, box), text, new FreeTextStyle("Helvetica", size), info: new AnnotationInfo(Date: now));
        TurnToPage(document, note, rect, pdfPage.Rotate);
        return tab.Commit(Loc.T("Place text"));
    }

    // On a page turned a quarter the user rectangle is the display box on its side. The appearance is drawn as the page
    // shows it, at the size of the display box, and its matrix turns it into the page's own space (ISO 32000-1 12.5.5).
    private static PdfRect AsShown(PdfRect user, DisplayRect box) => new(user.Left, user.Bottom, user.Left + box.Width, user.Bottom + box.Height);

    private static void TurnToPage(PdfDocument document, PdfAnnotation annotation, PdfRect user, int rotate)
    {
        if (rotate == 0) return;
        var d = annotation.Dictionary;
        d["Rect"] = new PdfArray([new PdfNumber(user.Left), new PdfNumber(user.Bottom), new PdfNumber(user.Right), new PdfNumber(user.Top)]);
        if (document.Resolve(document.Dict(d, "AP")?["N"]) is not PdfStream form) return;
        (int a, int b) = rotate switch { 90 => (0, 1), 180 => (-1, 0), _ => (0, -1) };
        form.Dictionary["Matrix"] = new PdfArray([new PdfNumber(a), new PdfNumber(b), new PdfNumber(-b), new PdfNumber(a), new PdfNumber(0), new PdfNumber(0)]);
    }

    // The box has to hold the text on its own lines, so it is measured with a font of about the same width as the one drawn.
    private static (double Width, double Height) Measure(string text, double size)
    {
        double width = 0;
        var lines = text.Split('\n');
        foreach (string line in lines)
        {
            var formatted = new FormattedText(line, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Arial"), size, Brushes.Black, 1.0);
            width = Math.Max(width, formatted.WidthIncludingTrailingWhitespace);
        }
        return (Math.Ceiling(width) + 8, Math.Ceiling(lines.Length * size * 1.25) + 4);
    }
}
