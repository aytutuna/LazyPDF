using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Signatures;

internal static class SignatureFields
{
    /// <summary>The page and box, in user space, of the first widget of each signature field of the file, by the field's full name.</summary>
    public static Dictionary<string, (int Page, PdfRect Rect)> Locate(byte[] file, string? password, X509Certificate2? certificate)
    {
        var document = certificate is null ? PdfDocument.Open(file, password) : PdfDocument.Open(file, certificate);
        return PdfForm.Read(document).Fields
            .Where(f => f.Kind == FieldKind.Signature && f.Widgets.Count > 0)
            .DistinctBy(f => f.Name)
            .ToDictionary(f => f.Name, f => (f.Widgets[0].PageIndex, f.Widgets[0].Rect));
    }
}
