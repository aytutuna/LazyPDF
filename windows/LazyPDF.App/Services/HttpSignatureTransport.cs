using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
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
    private const int MaxRedirects = 5;
    private static readonly HttpRequestOptionsKey<bool> Refused = new("LazyPDF.Refused");

    private readonly HttpClient _client;
    private int _requests;

    public HttpSignatureTransport(HttpMessageHandler? handler = null)
    {
        _client = handler is null ? new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, ConnectCallback = ConnectAsync }) : new HttpClient(handler);
        _client.Timeout = Timeout.InfiniteTimeSpan;
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
        if (!Uri.TryCreate(url, UriKind.Absolute, out var address))
            return NotAWebAddress();
        if (IsOffline)
        {
            LastFailure = Loc.T("This computer is offline. Connect to the internet and try again.");
            return null;
        }
        // The timeout has to cover reading the body too, which HttpClient.Timeout does not once headers are read.
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(Cancel);
        limit.CancelAfter(TimeSpan.FromSeconds(20));
        HttpRequestMessage? sent = null;
        try
        {
            for (int hop = 0; ; hop++)
            {
                if (address.Scheme is not ("http" or "https"))
                    return NotAWebAddress();
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
                using var request = new HttpRequestMessage(method, address) { Content = content };
                sent = request;
                using var response = _client.Send(request, HttpCompletionOption.ResponseHeadersRead, limit.Token);
                // Redirects are followed here so every address gets the checks above. Only a fetch is repeated.
                if (response.Headers.Location is { } next && (int)response.StatusCode is >= 300 and < 400 && method == HttpMethod.Get && hop < MaxRedirects)
                {
                    address = new Uri(address, next);
                    continue;
                }
                if (!response.IsSuccessStatusCode)
                {
                    LastFailure = Loc.T("The server answered with an error ({0}).", (int)response.StatusCode);
                    return null;
                }
                if (response.Content.Headers.ContentLength > MaxResponseBytes)
                    return TooLarge();
                using var stop = limit.Token.Register(response.Dispose);
                using var body = new MemoryStream();
                using var stream = response.Content.ReadAsStream(limit.Token);
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
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException or ObjectDisposedException)
        {
            LastFailure = sent is not null && sent.Options.TryGetValue(Refused, out var refused) && refused ? Loc.T("The address points to this computer, so it was not used.")
                : e is OperationCanceledException || limit.IsCancellationRequested
                ? Loc.T("The server did not answer in time. Try again later.")
                : Loc.T("The server could not be reached. Check the connection and try again.");
            return null;
        }
    }

    private byte[]? NotAWebAddress()
    {
        LastFailure = Loc.T("The address is not a web address.");
        return null;
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
        return IPAddress.TryParse(host, out var ip) && PointsHere(ip);
    }

    private static bool PointsHere(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6)
            ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip) || ip.IsIPv6LinkLocal)
            return true;
        byte[] b = ip.GetAddressBytes();
        return b.Length == 4 && b[0] == 169 && b[1] == 254;
    }

    // Checks the addresses the name resolves to, which the host text cannot show, and connects to the first allowed one that answers.
    private async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken token)
    {
        var uri = context.InitialRequestMessage?.RequestUri;
        var port = context.DnsEndPoint.Port;
        List<EndPoint> targets = [];
        // A different endpoint than the request's own is a proxy, which the user configured.
        if (uri is null || port != uri.Port || !context.DnsEndPoint.Host.Equals(uri.IdnHost, StringComparison.OrdinalIgnoreCase))
            targets.Add(context.DnsEndPoint);
        else
            targets.AddRange((await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, token)).Where(a => !PointsHere(a)).Select(a => new IPEndPoint(a, port)));
        if (targets.Count == 0)
        {
            context.InitialRequestMessage?.Options.Set(Refused, true);
            throw new HttpRequestException("The address points to this computer.");
        }
        SocketException? last = null;
        foreach (var target in targets)
        {
            var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await socket.ConnectAsync(target, token);
                return new NetworkStream(socket, true);
            }
            catch (SocketException e)
            {
                socket.Dispose();
                last = e;
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        }
        throw last!;
    }

    public void Dispose() => _client.Dispose();
}
