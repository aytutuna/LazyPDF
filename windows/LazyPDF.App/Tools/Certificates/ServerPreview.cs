using LazyPDF.Core;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>Which servers Add validation data would ask, found by running it against a transport that answers nothing.</summary>
internal static class ServerPreview
{
    private const int Shown = 6;

    private sealed class Recorder : ISignatureTransport
    {
        public HashSet<string> Urls { get; } = [];

        public byte[]? Post(string url, string contentType, byte[] body)
        {
            Urls.Add(url);
            return null;
        }

        public byte[]? Get(string url)
        {
            Urls.Add(url);
            return null;
        }
    }

    public static Task<IReadOnlyList<string>> HostsAsync(byte[] file, string? password) => Task.Run<IReadOnlyList<string>>(() =>
    {
        var recorder = new Recorder();
        try { PdfLongTermValidation.Add(file, recorder, DateTimeOffset.Now, password); }
        catch (Exception error) when (error is InvalidOperationException or PdfReadException) { return []; }
        return recorder.Urls.Select(Host).OfType<string>().Distinct().ToList();
    });

    /// <summary>The servers a check would ask for missing issuer certificates, found by verifying against a transport that answers nothing.</summary>
    public static Task<IReadOnlyList<string>> IssuerHostsAsync(byte[] file, VerifyOptions options) => Task.Run<IReadOnlyList<string>>(() =>
    {
        var recorder = new Recorder();
        try { PdfSignatureVerifier.Verify(file, options with { Transport = recorder }); }
        catch (PdfReadException) { return []; }
        return recorder.Urls.Select(Host).OfType<string>().Distinct().ToList();
    });

    public static string Describe(IReadOnlyList<string> hosts) =>
        hosts.Count <= Shown ? string.Join(", ", hosts) : Loc.T("{0}, and {1} more", string.Join(", ", hosts.Take(Shown)), hosts.Count - Shown);

    private static string? Host(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        string host = uri.IsDefaultPort ? uri.IdnHost : uri.IdnHost + ":" + uri.Port;
        return uri.Scheme == Uri.UriSchemeHttp ? Loc.T("{0} (not encrypted)", host) : host;
    }
}
