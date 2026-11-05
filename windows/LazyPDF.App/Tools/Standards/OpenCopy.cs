using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Standards;

/// <summary>A second reading of the tab's file for work that runs off the UI thread and must not touch the open document.</summary>
internal static class OpenCopy
{
    // The session never changes an array it has handed out, so the bytes are taken here and copied and parsed on the worker.
    public static Func<PdfDocument> Of(DocumentTab tab)
    {
        var bytes = tab.Session.Current;
        string? password = tab.Password;
        var certificate = tab.Certificate;
        return () =>
        {
            byte[] copy = bytes.ToArray();
            return certificate is null ? PdfDocument.Open(copy, password) : PdfDocument.Open(copy, certificate);
        };
    }
}
