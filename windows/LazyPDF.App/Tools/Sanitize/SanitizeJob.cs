using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Optimize;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Sanitize;

internal static class SanitizeJob
{
    public static IReadOnlyList<SanitizeFinding> Scan(byte[] file, string? password, X509Certificate2? certificate)
    {
        using var document = OptimizeJob.Open(file, password, certificate);
        return new PdfSanitizer(document).Scan();
    }

    public static SanitizeResult Run(byte[] file, string? password, X509Certificate2? certificate, IReadOnlySet<SanitizeItem> ticked, CancellationToken token)
    {
        using var document = OptimizeJob.Open(file, password, certificate);
        var result = new PdfSanitizer(document).Run(Options(ticked));
        token.ThrowIfCancellationRequested();
        return result;
    }

    public static SanitizeOptions Options(IReadOnlySet<SanitizeItem> ticked) => new()
    {
        JavaScript = ticked.Contains(SanitizeItem.JavaScript),
        LaunchActions = ticked.Contains(SanitizeItem.LaunchActions),
        EmbeddedFiles = ticked.Contains(SanitizeItem.EmbeddedFiles),
        HiddenLayers = ticked.Contains(SanitizeItem.HiddenLayers),
        InvisibleText = ticked.Contains(SanitizeItem.InvisibleText),
        Comments = ticked.Contains(SanitizeItem.Comments),
        FormData = ticked.Contains(SanitizeItem.FormData),
        Metadata = ticked.Contains(SanitizeItem.Metadata),
        PieceInfo = ticked.Contains(SanitizeItem.PieceInfo),
        Thumbnails = ticked.Contains(SanitizeItem.Thumbnails),
        SearchIndexes = ticked.Contains(SanitizeItem.SearchIndexes),
        ExternalLinks = ticked.Contains(SanitizeItem.ExternalLinks),
        FilePaths = ticked.Contains(SanitizeItem.FilePaths),
    };

    /// <summary>"Comments and markup (14)" for each finding, joined.</summary>
    public static string List(IEnumerable<SanitizeFinding> findings) =>
        string.Join("; ", findings.Select(f => Loc.T("{0} ({1})", OptimizeText.ItemName(f.Item), f.Count)));
}
