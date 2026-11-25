using System.Text;

namespace LazyPDF.Core;

internal static class ExportPdf
{
    private const double A4Width = 595.276, A4Height = 841.89;
    private const double LetterWidth = 612, LetterHeight = 792;
    private const double A3Width = 841.89, A3Height = 1190.551;
    private const double A5Width = 419.528, A5Height = 595.276;
    private const double LegalHeight = 1008;
    private const double MinSide = 3, MaxSide = 14400;

    // A file of a catalog and an empty tree, with a proper table so that opening it needs no repair.
    public static PdfDocument NewDocument()
    {
        const string head = "%PDF-1.7\n%âãÏÓ\n";
        const string catalog = "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n";
        const string tree = "2 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n";
        int first = head.Length, second = first + catalog.Length, table = second + tree.Length;
        string end = $"xref\n0 3\n0000000000 65535 f \n{first:D10} 00000 n \n{second:D10} 00000 n \ntrailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n{table}\n%%EOF\n";
        return PdfDocument.Open(Encoding.Latin1.GetBytes(head + catalog + tree + end));
    }

    /// <summary>The paper in portrait, turned when landscape. <see cref="PdfPaper.Picture"/> reads as A4.</summary>
    public static (double Width, double Height) Paper(PdfPageSetup setup, bool landscape)
    {
        var (w, h) = setup.Paper switch
        {
            PdfPaper.Letter => (LetterWidth, LetterHeight),
            PdfPaper.A3 => (A3Width, A3Height),
            PdfPaper.A5 => (A5Width, A5Height),
            PdfPaper.Legal => (LetterWidth, LegalHeight),
            PdfPaper.Custom => (Math.Min(Side(setup.CustomWidth), Side(setup.CustomHeight)), Math.Max(Side(setup.CustomWidth), Side(setup.CustomHeight))),
            _ => (A4Width, A4Height),
        };
        landscape = setup.Orientation switch { PdfOrientation.Portrait => false, PdfOrientation.Landscape => true, _ => landscape };
        return landscape ? (h, w) : (w, h);
    }

    private static double Side(double value) => double.IsNaN(value) ? MinSide : Math.Clamp(value, MinSide, MaxSide);
}
