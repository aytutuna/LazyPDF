namespace LazyPDF.App.Tools.Pages;

/// <summary>Pages cut or copied in the organize view, as a PDF of just those pages, for pasting into any open tab.</summary>
internal static class PageClipboard
{
    public static byte[]? Pdf { get; private set; }

    public static int Count { get; private set; }

    public static void Set(byte[] pdf, int count)
    {
        Pdf = pdf;
        Count = count;
    }
}
