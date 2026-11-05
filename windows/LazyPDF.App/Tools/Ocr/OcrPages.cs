using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Ocr;

/// <summary>A page in the list, with what triage found on it.</summary>
public sealed record PageRow(int Page, OcrPageKind Kind)
{
    public string Label => Loc.T("Page {0}", Page + 1);

    public string KindText => Kind switch
    {
        OcrPageKind.Picture => Loc.T("Scan|noun"),
        OcrPageKind.Drawing => Loc.T("Drawing"),
        OcrPageKind.OwnLayer => Loc.T("Searchable"),
        OcrPageKind.ForeignLayer => Loc.T("Hidden text"),
        OcrPageKind.Text => Loc.T("Has text"),
        _ => Loc.T("Blank"),
    };

    public override string ToString() => Label + ", " + KindText;
}

public static class OcrPages
{
    /// <summary>Triage of a copy of the file, so it can run while the file is in use.</summary>
    public static IReadOnlyList<OcrPageKind> Classify(byte[] bytes, string? password, X509Certificate2? certificate)
    {
        return OcrTriage.ClassifyAll(Open(bytes, password, certificate));
    }

    public static PdfDocument Open(byte[] bytes, string? password, X509Certificate2? certificate) =>
        certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate);

    /// <summary>The pages that need reading first, then the rest, each group in page order.</summary>
    public static IReadOnlyList<PageRow> Rows(IReadOnlyList<OcrPageKind> kinds) =>
        [.. kinds.Select((kind, page) => new PageRow(page, kind)).OrderBy(row => Rank(row.Kind))];

    /// <summary>Whether a page is picked when the list is first shown.</summary>
    public static bool Wanted(PageRow row, bool replace) => OcrTriage.NeedsOcr(row.Kind, replace, force: false);

    private static int Rank(OcrPageKind kind) => kind switch
    {
        OcrPageKind.Picture => 0,
        OcrPageKind.Drawing => 1,
        OcrPageKind.ForeignLayer => 2,
        OcrPageKind.OwnLayer => 3,
        OcrPageKind.Text => 4,
        _ => 5,
    };
}
