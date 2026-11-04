using LazyPDF.Core;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>Lets Cancel end a signing that waits on a server: a request that was cancelled or answers after Cancel throws instead of going on.</summary>
internal sealed class CancellableTransport(ISignatureTransport inner, CancellationToken token) : ISignatureTransport
{
    public byte[]? Post(string url, string contentType, byte[] body)
    {
        token.ThrowIfCancellationRequested();
        var answer = inner.Post(url, contentType, body);
        token.ThrowIfCancellationRequested();
        return answer;
    }

    public byte[]? Get(string url)
    {
        token.ThrowIfCancellationRequested();
        var answer = inner.Get(url);
        token.ThrowIfCancellationRequested();
        return answer;
    }
}
