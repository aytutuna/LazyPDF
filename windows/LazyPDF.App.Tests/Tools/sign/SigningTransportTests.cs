using System.Net.Http;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// What the transport does with an address nobody checked, and with Cancel.
public sealed class SigningTransportTests
{
    private sealed class Waits : HttpMessageHandler
    {
        protected override HttpResponseMessage Send(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.WaitHandle.WaitOne(TimeSpan.FromSeconds(10));
            cancellationToken.ThrowIfCancellationRequested();
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent([1]) };
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(Send(request, cancellationToken));
    }

    [Theory]
    [InlineData("timestamp.digicert.com")]
    [InlineData("http://")]
    [InlineData("http://a b/")]
    [InlineData("")]
    public void AnAddressThatIsNotAWebAddressGivesNullAndTheReason(string address)
    {
        using var transport = new HttpSignatureTransport(new Waits());

        Assert.Null(transport.Post(address, "a/b", [1]));
        Assert.Equal("The address is not a web address.", transport.LastFailure);
        Assert.Null(transport.Get(address));
        Assert.Equal("The address is not a web address.", transport.LastFailure);
    }

    [Fact]
    public async Task CancelEndsARequestThatIsWaiting()
    {
        if (HttpSignatureTransport.IsOffline) return;
        using var cancel = new CancellationTokenSource();
        using var transport = new HttpSignatureTransport(new Waits()) { Cancel = cancel.Token };

        var request = Task.Run(() => transport.Get("https://tsa.example/"));
        await Task.Delay(100);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        await cancel.CancelAsync();

        Assert.Null(await request);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
        Assert.NotNull(transport.LastFailure);
    }
}
