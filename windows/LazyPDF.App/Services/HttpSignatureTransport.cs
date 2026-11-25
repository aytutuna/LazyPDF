using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
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
    private readonly Dictionary<(string Method, string Url, string Body), (byte[]? Bytes, string? Failure)> _answers = [];
    private readonly Func<bool> _offline;
    private int _requests;

    public HttpSignatureTransport(HttpMessageHandler? handler = null, Func<bool>? offline = null)
    {
        _offline = offline ?? (() => IsOffline);
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
        return Send(HttpMethod.Post, url, body, contentType, Convert.ToHexString(SHA256.HashData(body)));
    }

    public byte[]? Get(string url) => Send(HttpMethod.Get, url, null, null, "");

    private byte[]? Send(HttpMethod method, string url, byte[]? payload, string? contentType, string bodyHash)
    {
        LastFailure = null;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var address))
            return NotAWebAddress();
        if (_offline())
        {
            LastFailure = Loc.T("This computer is offline. Connect to the internet and try again.");
            return null;
        }
        // A dead server is asked once per file, not once per signature.
        var key = (method.Method, address.AbsoluteUri, bodyHash);
        if (_answers.TryGetValue(key, out var known))
        {
            LastFailure = known.Failure;
            return known.Bytes;
        }
        var bytes = Fetch(method, address, payload, contentType, out bool keep);
        if (keep)
            _answers[key] = (bytes, LastFailure);
        return bytes;
    }

    // keep says the outcome is final; a cancel or a timeout may work on a later try.
    private byte[]? Fetch(HttpMethod method, Uri address, byte[]? payload, string? contentType, out bool keep)
    {
        keep = false;
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
                    keep = true;
                    return null;
                }
                if (++_requests > MaxRequests)
                {
                    LastFailure = Loc.T("Too many requests for one file. Stopped.");
                    return null;
                }
                // A request disposes its content, so every hop gets a new one.
                using var request = new HttpRequestMessage(method, address);
                if (payload is not null)
                {
                    request.Content = new ByteArrayContent(payload);
                    request.Content.Headers.TryAddWithoutValidation("Content-Type", contentType);
                }
                sent = request;
                using var response = _client.Send(request, HttpCompletionOption.ResponseHeadersRead, limit.Token);
                // Redirects are followed here so every address gets the checks above. A post is only repeated for 307 and 308, which keep method and body.
                if (response.Headers.Location is { } next && (int)response.StatusCode is >= 300 and < 400
                    && (method == HttpMethod.Get || response.StatusCode is HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect) && hop < MaxRedirects)
                {
                    var target = new Uri(address, next);
                    if (address.Scheme == "https" && target.Scheme == "http")
                    {
                        LastFailure = Loc.T("The server tried to move the request to an address that is not encrypted, so it was not used.");
                        keep = true;
                        return null;
                    }
                    address = target;
                    continue;
                }
                if (!response.IsSuccessStatusCode)
                {
                    LastFailure = Loc.T("The server answered with an error ({0}).", (int)response.StatusCode);
                    keep = true;
                    return null;
                }
                if (response.Content.Headers.ContentLength > MaxResponseBytes)
                {
                    keep = true;
                    return TooLarge();
                }
                using var stop = limit.Token.Register(response.Dispose);
                using var body = new MemoryStream();
                using var stream = response.Content.ReadAsStream(limit.Token);
                var buffer = new byte[80 * 1024];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    body.Write(buffer, 0, read);
                    if (body.Length > MaxResponseBytes)
                    {
                        keep = true;
                        return TooLarge();
                    }
                }
                keep = true;
                return body.ToArray();
            }
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException or ObjectDisposedException)
        {
            bool timedOut = e is OperationCanceledException || limit.IsCancellationRequested;
            LastFailure = sent is not null && sent.Options.TryGetValue(Refused, out var refused) && refused ? Loc.T("The address points to this computer, so it was not used.")
                : timedOut
                ? Loc.T("The server did not answer in time. Try again later.")
                : Loc.T("The server could not be reached. Check the connection and try again.");
            keep = !timedOut;
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
        // A different endpoint than the request's own is a proxy, which the user configured. So is the CONNECT request that opens an https tunnel through one.
        if (uri is null || context.InitialRequestMessage!.Method == HttpMethod.Connect || port != uri.Port || !context.DnsEndPoint.Host.Equals(uri.IdnHost, StringComparison.OrdinalIgnoreCase))
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
