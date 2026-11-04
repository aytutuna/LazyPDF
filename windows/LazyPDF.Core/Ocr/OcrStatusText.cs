namespace LazyPDF.Core;

/// <summary>Texts the OCR action raises to the user.</summary>
public static class OcrStatusText
{
    public static string Label => Loc.T("Make searchable");
    public static string Nothing => Loc.T("No pages need text recognition.");

    public static string Status(int page, int total) =>
        Loc.T("Reading page {0} of {1}", page, total);

    public static string StatusFull(int page, int total) =>
        Loc.T("Recognizing the text on page {0} of {1}.", page, total);
}
