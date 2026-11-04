using LazyPDF.Core;

namespace LazyPDF.App.Panels.Signatures;

internal static class SignedVersion
{
    /// <summary>The file as it was when <paramref name="report"/>'s signature closed it; null when that revision is not found.</summary>
    public static byte[]? Of(byte[] file, SignatureReport report) =>
        PdfRevisions.List(file).FirstOrDefault(r => r.Number == report.Revision) is { } revision ? PdfRevisions.Extract(file, revision) : null;
}
