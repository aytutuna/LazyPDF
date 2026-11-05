using System.Globalization;
using System.Windows;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Measure;

/// <summary>
/// Writes measurements as Line, PolyLine and Polygon annotations carrying a /Measure dictionary (ISO 32000-1 12.9, rectilinear),
/// so other readers show and extend them with the same scale. A free text box beside each shows the value in any viewer.
/// </summary>
public static class MeasureWriter
{
    private static readonly double[] Blue = [0.05, 0.38, 0.75];

    public static int Write(PdfDocument document, IEnumerable<MeasureItem> items, MeasureScale scale, string author, DateTimeOffset date, IFontSource? fonts = null)
    {
        var all = items.ToList();
        // Nothing is written unless every page is still there, so a refusal leaves the document as it was.
        if (all.Any(i => i.Page < 0 || i.Page >= document.Pages.Count)) throw new ArgumentException("A measurement lies on a page that is gone.", nameof(items));

        var writer = new PdfAnnotationWriter(document, fonts);
        foreach (var item in all)
        {
            var page = document.Pages[item.Page];
            var geometry = new PageGeometry(page);
            var points = item.Points.Select(p => geometry.ToUser(p.X, p.Y)).ToList();
            string value = item.Value(scale);
            var info = new AnnotationInfo(author, $"{item.Title}: {value}", item.Title, date);
            var style = new AnnotationStyle(Blue, 1.5);

            PdfAnnotation annotation;
            string intent;
            switch (item.Kind)
            {
                case MeasureKind.Distance:
                    annotation = writer.AddLine(page, points[0], points[1], style, info, LineEnding.Butt, LineEnding.Butt);
                    intent = "LineDimension";
                    break;
                case MeasureKind.Perimeter:
                    // Acrobat reads a closed polygon as an area, so the perimeter is an open polyline that comes back to its start.
                    annotation = writer.AddPolyLine(page, [.. points, points[0]], style, info);
                    intent = "PolyLineDimension";
                    break;
                default:
                    annotation = writer.AddPolygon(page, points, style, info);
                    intent = "PolygonDimension";
                    break;
            }
            annotation.Dictionary["IT"] = new PdfName(intent);
            annotation.Dictionary["Measure"] = MeasureDictionary(scale, page.UserUnit);

            AddLabel(document, writer, page, geometry, item.Middle, value, author, date);
        }
        return all.Count;
    }

    // X converts the units of the page's user space to the real unit; D and A convert from the unit of X, so their factor is 1.
    private static PdfDictionary MeasureDictionary(MeasureScale scale, double userUnit)
    {
        string unit = scale.RealUnit.Symbol();
        return new PdfDictionary
        {
            ["Type"] = new PdfName("Measure"),
            ["Subtype"] = new PdfName("RL"),
            ["R"] = PdfText.ToObject(scale.Ratio),
            ["X"] = Formats(unit, scale.PerPoint * userUnit),
            ["Y"] = Formats(unit, scale.PerPoint * userUnit),
            ["D"] = Formats(unit, 1),
            ["A"] = Formats(unit + "²", 1),
        };
    }

    private static PdfArray Formats(string unit, double factor) => new([new PdfDictionary
    {
        ["Type"] = new PdfName("NumberFormat"),
        ["U"] = PdfText.ToObject(unit),
        ["C"] = new PdfNumber(factor.ToString("0.############", CultureInfo.InvariantCulture)),
        ["F"] = new PdfName("D"),
        ["D"] = new PdfNumber(100L),
    }]);

    // The box is drawn upright in its own space; on a turned page its form is turned back and its rectangle is the shown one.
    private static void AddLabel(PdfDocument document, PdfAnnotationWriter writer, PdfPage page, PageGeometry geometry, Point at,
        string text, string author, DateTimeOffset date)
    {
        text = text.Replace(' ', ' ').Replace(' ', ' ');
        double width = text.Length * 5.5 + 8;
        var shown = geometry.ToUser(new DisplayRect(at.X - width / 2, at.Y - 7, width, 14));
        var upright = new PdfRect(shown.Left, shown.Bottom, shown.Left + width, shown.Bottom + 14);
        var style = new AnnotationStyle([0, 0, 0], 0, Fill: [1, 1, 1]);
        var font = new FreeTextStyle(Size: 10, TextColor: Blue, Alignment: 1);
        PdfAnnotation label;
        try { label = writer.AddFreeText(page, upright, text, font, style, new AnnotationInfo(author, Date: date)); }
        catch (InvalidOperationException) { return; }

        double[] turn = geometry.Rotation switch
        {
            90 => [0, 1, -1, 0, 0, 0],
            180 => [-1, 0, 0, -1, 0, 0],
            270 => [0, -1, 1, 0, 0, 0],
            _ => [],
        };
        if (turn.Length == 0) return;
        label.Dictionary["Rect"] = shown.ToArray();
        if (document.Resolve(label.Dictionary["AP"] is PdfDictionary ap ? ap["N"] : null) is PdfStream form)
            form.Dictionary["Matrix"] = new PdfArray([.. turn.Select(n => (PdfObject)new PdfNumber(n))]);
    }
}
