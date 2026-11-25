using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// The client for time stamps and OCSP: bytes in and out, and a plain reason when there are none.
public sealed class HttpSignatureTransportTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];
        public List<byte[]?> Bodies { get; } = [];
        public List<string?> ContentTypes { get; } = [];
        public byte[]? LastBody { get; private set; }

        protected override HttpResponseMessage Send(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            LastBody = request.Content?.ReadAsByteArrayAsync(cancellationToken).GetAwaiter().GetResult();
            Bodies.Add(LastBody);
            ContentTypes.Add(request.Content?.Headers.ContentType?.MediaType);
            return answer(request);
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(Send(request, cancellationToken));
    }

    private static HttpResponseMessage Ok(byte[] body) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(body) };

    [Fact]
    public void APostSendsTheBodyWithItsContentTypeAndGivesTheAnswer()
    {
        var handler = new Handler(_ => Ok([9, 8, 7]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        byte[]? answer = transport.Post("https://tsa.example/stamp", "application/timestamp-query", [1, 2, 3]);

        Assert.Equal(new byte[] { 9, 8, 7 }, answer);
        Assert.Equal(new byte[] { 1, 2, 3 }, handler.LastBody);
        Assert.Equal("application/timestamp-query", handler.Requests[0].Content!.Headers.ContentType!.MediaType);
        Assert.Null(transport.LastFailure);
    }

    [Fact]
    public void WithNoNetworkNothingIsSentAndTheReasonIsGiven()
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => true);

        Assert.Null(transport.Get("https://tsa.example/stamp"));
        Assert.Equal("This computer is offline. Connect to the internet and try again.", transport.LastFailure);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void AGetGivesTheBody()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => Ok([5])), () => false);

        Assert.Equal(new byte[] { 5 }, transport.Get("http://crl.example/ca.crl"));
    }

    [Fact]
    public void AnErrorStatusGivesNullAndTheCode()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)), () => false);

        Assert.Null(transport.Get("https://ocsp.example/"));
        Assert.Contains("503", transport.LastFailure);
    }

    [Fact]
    public void AServerThatCannotBeReachedGivesNullAndSaysSo()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => throw new HttpRequestException("no route")), () => false);

        Assert.Null(transport.Get("https://ocsp.example/"));
        Assert.Contains("could not be reached", transport.LastFailure);
    }

    [Fact]
    public void ASlowServerGivesNullAndSaysItDidNotAnswer()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => throw new TaskCanceledException()), () => false);

        Assert.Null(transport.Get("https://ocsp.example/"));
        Assert.Contains("did not answer", transport.LastFailure);
    }

    [Fact]
    public void TheSameGetIsAskedOnce()
    {
        var handler = new Handler(_ => Ok([4]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Equal(new byte[] { 4 }, transport.Get("http://crl.example/ca.crl"));
        Assert.Equal(new byte[] { 4 }, transport.Get("http://crl.example/ca.crl"));

        Assert.Single(handler.Requests);
    }

    [Fact]
    public void PostsWithDifferentBodiesAreBothSent()
    {
        var handler = new Handler(_ => Ok([4]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        transport.Post("https://tsa.example/stamp", "application/timestamp-query", [1]);
        transport.Post("https://tsa.example/stamp", "application/timestamp-query", [2]);

        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public void AFailingServerIsAskedOnceAndKeepsItsFailureText()
    {
        var handler = new Handler(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        using var transport = new HttpSignatureTransport(handler, () => false);

        for (int i = 0; i < 3; i++)
        {
            Assert.Null(transport.Get("https://ocsp.example/"));
            Assert.Contains("500", transport.LastFailure);
        }

        Assert.Single(handler.Requests);
    }

    [Fact]
    public void RepeatedAskingOfFewAddressesNeverHitsTheRequestCap()
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        for (int i = 0; i < 250; i++)
        {
            Assert.NotNull(transport.Get($"https://crl.example/{i % 10}.crl"));
            Assert.Null(transport.LastFailure);
        }

        Assert.Equal(10, handler.Requests.Count);
    }

    [Fact]
    public void ACancelledCallIsNotRemembered()
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => false);
        using var source = new CancellationTokenSource();
        source.Cancel();
        transport.Cancel = source.Token;

        Assert.Null(transport.Get("https://ocsp.example/"));
        transport.Cancel = CancellationToken.None;

        Assert.Equal(new byte[] { 1 }, transport.Get("https://ocsp.example/"));
    }

    [Theory]
    [InlineData("file:///C:/secret.txt")]
    [InlineData("ftp://host/a")]
    public void OnlyWebAddressesAreFetched(string url)
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Get(url));
        Assert.Empty(handler.Requests);
        Assert.NotNull(transport.LastFailure);
    }

    [Theory]
    [InlineData("http://localhost/a")]
    [InlineData("https://crl.localhost/a")]
    [InlineData("http://127.0.0.1:8080/a")]
    [InlineData("http://[::1]/a")]
    [InlineData("http://169.254.169.254/latest")]
    [InlineData("http://[fe80::1]/a")]
    [InlineData("http://[::ffff:127.0.0.1]/a")]
    public void AddressesOnThisComputerAreRefused(string url)
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Get(url));
        Assert.Empty(handler.Requests);
        Assert.Contains("this computer", transport.LastFailure);
    }

    [Fact]
    public void ALocalNetworkAddressIsNotRefusedAsThisComputer()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => Ok([1])), () => false);

        transport.Get("http://192.168.1.5/ca.crl");

        Assert.DoesNotContain("this computer, so", transport.LastFailure);
    }

    [Fact]
    public async Task AnHttpsFetchThroughALocalProxyReachesTheProxy()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var saved = HttpClient.DefaultProxy;
        try
        {
            HttpClient.DefaultProxy = new WebProxy($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}");
            var accepted = Task.Run(() => listener.AcceptTcpClient().Dispose());
            using var transport = new HttpSignatureTransport(null, () => false);

            Assert.Null(transport.Get("https://ocsp.example/"));

            await accepted.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.DoesNotContain("this computer", transport.LastFailure);
        }
        finally
        {
            HttpClient.DefaultProxy = saved;
            listener.Stop();
        }
    }

    [Fact]
    public void TheTwoHundredFirstRequestIsRefused()
    {
        var handler = new Handler(_ => Ok([1]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        for (int i = 0; i < 200; i++)
            Assert.NotNull(transport.Get($"https://a.example/{i}"));

        Assert.Null(transport.Get("https://a.example/200"));
        Assert.Contains("Too many requests", transport.LastFailure);
        Assert.Equal(200, handler.Requests.Count);
    }

    private sealed class Endless : Stream
    {
        public long Served { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) { Served += count; return count; }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public void ABodyWithoutALengthIsNotReadPastTheLimit()
    {
        var body = new Endless();
        using var transport = new HttpSignatureTransport(new Handler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) }), () => false);

        Assert.Null(transport.Get("https://ocsp.example/"));
        Assert.Contains("too large", transport.LastFailure);
        Assert.InRange(body.Served, 8 << 20, (8 << 20) + (256 << 10));
    }

    [Fact]
    public void ARedirectToThisComputerIsRefused()
    {
        var handler = new Handler(_ => new HttpResponseMessage(HttpStatusCode.Found) { Headers = { Location = new Uri("http://127.0.0.1:8080/x") } });
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Get("http://crl.example/ca.crl"));
        Assert.Single(handler.Requests);
        Assert.Contains("this computer", transport.LastFailure);
    }

    [Fact]
    public void ARedirectToAnotherWebAddressIsFollowed()
    {
        var handler = new Handler(r => r.RequestUri!.Host == "crl.example"
            ? new HttpResponseMessage(HttpStatusCode.Found) { Headers = { Location = new Uri("https://cdn.example/ca.crl") } }
            : Ok([4]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Equal(new byte[] { 4 }, transport.Get("http://crl.example/ca.crl"));
    }

    [Theory]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    [InlineData(HttpStatusCode.PermanentRedirect)]
    public void APostIsRepeatedWithTheSameBodyAfterA307Or308(HttpStatusCode status)
    {
        var handler = new Handler(r => r.RequestUri!.Host == "tsa.example"
            ? new HttpResponseMessage(status) { Headers = { Location = new Uri("https://tsa2.example/stamp") } }
            : Ok([9]));
        using var transport = new HttpSignatureTransport(handler, () => false);

        byte[]? answer = transport.Post("http://tsa.example/stamp", "application/timestamp-query", [1, 2, 3]);

        Assert.Equal(new byte[] { 9 }, answer);
        Assert.Equal(2, handler.Requests.Count);
        Assert.All(handler.Requests, r => Assert.Equal(HttpMethod.Post, r.Method));
        Assert.Equal(new byte[] { 1, 2, 3 }, handler.Bodies[1]);
        Assert.Equal("application/timestamp-query", handler.ContentTypes[1]);
    }

    [Fact]
    public void APostAnsweredWith302IsNotRepeated()
    {
        var handler = new Handler(_ => new HttpResponseMessage(HttpStatusCode.Found) { Headers = { Location = new Uri("https://tsa2.example/stamp") } });
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Post("https://tsa.example/stamp", "application/timestamp-query", [1]));
        Assert.Single(handler.Requests);
        Assert.Contains("302", transport.LastFailure);
    }

    [Theory]
    [InlineData(HttpStatusCode.MovedPermanently)]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    public void ARedirectFromHttpsToHttpIsRefused(HttpStatusCode status)
    {
        var handler = new Handler(_ => new HttpResponseMessage(status) { Headers = { Location = new Uri("http://tsa.example/stamp") } });
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Get("https://tsa.example/stamp"));
        Assert.Contains("not encrypted", transport.LastFailure);
        if (status == HttpStatusCode.TemporaryRedirect)
        {
            Assert.Null(transport.Post("https://tsa.example/other", "application/timestamp-query", [1]));
            Assert.Contains("not encrypted", transport.LastFailure);
        }
    }

    [Fact]
    public void ALoopOf307AnswersStopsAtTheRedirectLimit()
    {
        var handler = new Handler(_ => new HttpResponseMessage(HttpStatusCode.TemporaryRedirect) { Headers = { Location = new Uri("https://tsa.example/stamp") } });
        using var transport = new HttpSignatureTransport(handler, () => false);

        Assert.Null(transport.Post("https://tsa.example/stamp", "application/timestamp-query", [1]));
        Assert.Equal(6, handler.Requests.Count);
        Assert.Contains("307", transport.LastFailure);
    }

    [Fact]
    public void AnAnswerThatIsTooLargeIsRefused()
    {
        using var transport = new HttpSignatureTransport(new Handler(_ => Ok(new byte[9 << 20])), () => false);

        Assert.Null(transport.Get("https://ocsp.example/"));
        Assert.Contains("too large", transport.LastFailure);
    }

    [Fact]
    public void ASuccessClearsTheLastFailure()
    {
        int calls = 0;
        using var transport = new HttpSignatureTransport(new Handler(_ => ++calls == 1 ? new HttpResponseMessage(HttpStatusCode.NotFound) : Ok([1])), () => false);

        transport.Get("https://a.example/1");
        Assert.NotNull(transport.LastFailure);
        transport.Get("https://a.example/2");

        Assert.Null(transport.LastFailure);
    }
}
