using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Optimize;

internal sealed record OptimizeOutcome(byte[] Bytes, OptimizeResult Result);

internal static class OptimizeJob
{
    public static PdfDocument Open(byte[] file, string? password, X509Certificate2? certificate) =>
        certificate is null ? PdfDocument.Open(file, password) : PdfDocument.Open(file, certificate);

    /// <summary>True when the file restricts what may be done to it and was not opened with the owner's rights, so a rewrite is refused.</summary>
    public static bool NeedsOwner(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false, Permissions: not PdfPermissions.All };

    public static SpaceAudit Audit(byte[] file, string? password, X509Certificate2? certificate)
    {
        using var document = Open(file, password, certificate);
        return new PdfOptimizer(document).Audit();
    }

    public static OptimizeOutcome Run(byte[] file, string? password, X509Certificate2? certificate, OptimizeChoice choice, IImageCodec codec, CancellationToken token)
    {
        using var document = Open(file, password, certificate);
        // The older handlers make their keys from the first /ID, which the optimizer's unencrypted working copy no longer shows.
        var options = choice.Options(document.Security) with { DocumentId = document.Security is null ? null : document.FirstId };
        var result = new PdfOptimizer(document, codec).Run(options);
        token.ThrowIfCancellationRequested();
        if (!choice.FastWebView) return new OptimizeOutcome(result.Bytes, result);

        using var optimized = Open(result.Bytes, password, certificate);
        byte[] web = optimized.SaveLinearized(new PdfSaveOptions(Security: optimized.Security));
        token.ThrowIfCancellationRequested();
        return new OptimizeOutcome(web, result with { SizeAfter = web.Length });
    }
}
