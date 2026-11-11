using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// Posting and fetching for time stamps, OCSP, CRLs and issuer certificates. Core wants null when a
/// request fails; <see cref="LastFailure"/> says why in words a person can act on, and
/// <see cref="IsOffline"/> lets a tool ask first.
/// </summary>
public sealed class HttpSignatureTransport : ISignatureTransport, IDisposable
{
    private const int MaxResponseBytes = 8 << 20;
    private const int MaxRequests = 200;

    private readonly HttpClient _client;
    private int _requests;

    public HttpSignatureTransport(HttpMessageHandler? handler = null)
    {
        _client = handler is null ? new HttpClient() : new HttpClient(handler);
        _client.Timeout = TimeSpan.FromSeconds(20);
    }

    /// <summary>Why the last request gave nothing; null after one that worked.</summary>
    public string? LastFailure { get; private set; }

    /// <summary>Ends the request in flight and fails the ones after it.</summary>
    public CancellationToken Cancel { get; set; }

    public static bool IsOffline => !NetworkInterface.GetIsNetworkAvailable();

    public byte[]? Post(string url, string contentType, byte[] body)
    {
        var content = new ByteArrayContent(body);
        content.Headers.TryAddWithoutValidation("Content-Type", contentType);
        return Send(HttpMethod.Post, url, content);
    }

    public byte[]? Get(string url) => Send(HttpMethod.Get, url, null);

    private byte[]? Send(HttpMethod method, string url, HttpContent? content)
    {
        LastFailure = null;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var address) || address.Scheme is not ("http" or "https"))
        {
            LastFailure = Loc.T("The address is not a web address.");
            return null;
        }
        if (PointsHere(address))
        {
            LastFailure = Loc.T("The address points to this computer, so it was not used.");
            return null;
        }
        if (++_requests > MaxRequests)
        {
            LastFailure = Loc.T("Too many requests for one file. Stopped.");
            return null;
        }
        if (IsOffline)
        {
            LastFailure = Loc.T("This computer is offline. Connect to the internet and try again.");
            return null;
        }
        try
        {
            using var request = new HttpRequestMessage(method, address) { Content = content };
            using var response = _client.Send(request, Cancel);
            if (!response.IsSuccessStatusCode)
            {
                LastFailure = Loc.T("The server answered with an error ({0}).", (int)response.StatusCode);
                return null;
            }
            if (response.Content.Headers.ContentLength > MaxResponseBytes)
                return TooLarge();
            using var body = new MemoryStream();
            using var stream = response.Content.ReadAsStream(Cancel);
            var buffer = new byte[80 * 1024];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                body.Write(buffer, 0, read);
                if (body.Length > MaxResponseBytes)
                    return TooLarge();
            }
            return body.ToArray();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
        {
            LastFailure = e is TaskCanceledException
                ? Loc.T("The server did not answer in time. Try again later.")
                : Loc.T("The server could not be reached. Check the connection and try again.");
            return null;
        }
    }

    private byte[]? TooLarge()
    {
        LastFailure = Loc.T("The server's answer is too large.");
        return null;
    }

    // Private LAN ranges stay allowed, since company PKI serves its CRLs from them.
    private static bool PointsHere(Uri address)
    {
        string host = address.DnsSafeHost.TrimEnd('.');
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase))
            return true;
        if (!IPAddress.TryParse(host, out var ip))
            return false;
        if (ip.IsIPv4MappedToIPv6)
            ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip) || ip.IsIPv6LinkLocal)
            return true;
        byte[] b = ip.GetAddressBytes();
        return b.Length == 4 && b[0] == 169 && b[1] == 254;
    }

    public void Dispose() => _client.Dispose();
}
