using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What a web page file may load, and the paper it is drawn on. The web view itself needs the runtime and a window.
[Collection("Application")]
public sealed class WebPageRulesTests
{
    [Theory]
    [InlineData("https://page.lazypdf.invalid/style.css")]
    [InlineData("https://page.lazypdf.invalid/img/a%20b.png")]
    [InlineData("https://PAGE.lazypdf.invalid/Index.HTML")]
    [InlineData("data:image/png;base64,AAAA")]
    [InlineData("about:blank")]
    public void LocalResourcesBesideThePageLoad(string address) => Assert.True(WebPageRules.IsAllowed(address));

    [Theory]
    [InlineData("http://example.com/a.css")]
    [InlineData("https://example.com/")]
    [InlineData("ftp://example.com/a.png")]
    [InlineData("ws://example.com/")]
    [InlineData("blob:https://example.com/1")]
    [InlineData("file:///C:/Docs/Site/style.css")]
    [InlineData("file:///C:/Users/x/Pictures/id.jpg")]
    [InlineData("file://server/share/a.css")]
    [InlineData("https://page.lazypdf.invalid.example.com/a.css")]
    [InlineData("https://page.lazypdf.invalid:8443/a.css")]
    [InlineData("https://user@page.lazypdf.invalid/a.css")]
    [InlineData("http://page.lazypdf.invalid/a.css")]
    [InlineData("//example.com/a.css")]
    [InlineData("not an address")]
    [InlineData("")]
    public void EverythingElseIsBlocked(string address) => Assert.False(WebPageRules.IsAllowed(address));

    [Theory]
    [InlineData(@"C:\x\Report.html", "https://page.lazypdf.invalid/Report.html")]
    [InlineData(@"C:\x\My Report #1.HTM", "https://page.lazypdf.invalid/My%20Report%20%231.HTM")]
    [InlineData(@"E:\index.html", "https://page.lazypdf.invalid/index.html")]
    public void ThePageIsOpenedThroughTheVirtualHost(string file, string expected)
    {
        Assert.Equal(expected, WebPageRules.PageAddress(file));
        Assert.True(WebPageRules.IsAllowed(expected));
    }

    [Theory]
    [InlineData("a.html", true)]
    [InlineData("A.HTM", true)]
    [InlineData("a.xhtml", false)]
    [InlineData("a.pdf", false)]
    public void OnlyHtmlFilesAreWebPages(string name, bool expected) => Assert.Equal(expected, WebPageRules.IsWebPage(name));

    [Theory]
    [InlineData(PdfPaper.A4, PdfOrientation.Auto, 8.2677, 11.6929)]
    [InlineData(PdfPaper.A4, PdfOrientation.Landscape, 11.6929, 8.2677)]
    [InlineData(PdfPaper.Letter, PdfOrientation.Portrait, 8.5, 11)]
    [InlineData(PdfPaper.Letter, PdfOrientation.Landscape, 11, 8.5)]
    [InlineData(PdfPaper.A3, PdfOrientation.Auto, 11.6929, 16.5354)]
    [InlineData(PdfPaper.A5, PdfOrientation.Landscape, 8.2677, 5.8268)]
    [InlineData(PdfPaper.Legal, PdfOrientation.Portrait, 8.5, 14)]
    [InlineData(PdfPaper.Legal, PdfOrientation.Landscape, 14, 8.5)]
    public void PaperIsInchesAndFollowsTheOrientation(PdfPaper paper, PdfOrientation orientation, double width, double height)
    {
        var layout = WebPageRules.Layout(new PdfPageSetup(paper, orientation, 36));

        Assert.Equal(width, layout.Width, 4);
        Assert.Equal(height, layout.Height, 4);
        Assert.Equal(0.5, layout.Margin, 6);
    }

    [Theory]
    [InlineData(PdfOrientation.Portrait, 100, 150)]
    [InlineData(PdfOrientation.Landscape, 150, 100)]
    public void ACustomSizeIsUsedAndTurnedByTheOrientation(PdfOrientation orientation, double widthMm, double heightMm)
    {
        var setup = new PdfPageSetup(PdfPaper.Custom, orientation, 0, CustomWidth: 100 / 25.4 * 72, CustomHeight: 150 / 25.4 * 72);

        var layout = WebPageRules.Layout(setup);

        Assert.Equal(widthMm / 25.4, layout.Width, 4);
        Assert.Equal(heightMm / 25.4, layout.Height, 4);
    }

    [Fact]
    public void ANoMarginIsAllowed() => Assert.Equal(0, WebPageRules.Layout(new PdfPageSetup(PdfPaper.A4, PdfOrientation.Auto, 0)).Margin);

    [Fact]
    public void AMarginThatLeavesNoRoomIsRefused() =>
        Assert.Throws<ArgumentException>(() => WebPageRules.Layout(new PdfPageSetup(PdfPaper.Letter, PdfOrientation.Landscape, 306)));

    private static readonly CreateRequest WebRequest = new(CreateSource.WebPage, new PdfPageSetup(PdfPaper.A4, PdfOrientation.Auto, 36), "page.pdf");

    [Fact]
    public void ARuntimeThatIsMissingIsSaidPlainly()
    {
        var problem = CreateProblems.Failed(new WebViewMissingException(), WebRequest);

        Assert.Equal("Web pages need WebView2", problem.Title);
        Assert.Contains("WebView2 Runtime", problem.Text);
    }

    [Fact]
    public void APageThatCannotBeDrawnIsNotCalledAPicture()
    {
        var problem = CreateProblems.Failed(new IOException(), WebRequest);

        Assert.Equal("Web page cannot be drawn", problem.Title);
    }

    [Fact]
    public void AReadErrorOfTheViewResultIsAWebPageProblemNotAWordOne()
    {
        var problem = CreateProblems.Failed(new PdfReadException(PdfReadProblem.Damaged, "bad"), WebRequest);

        Assert.Equal("Web page cannot be drawn", problem.Title);
    }

    [Theory]
    [InlineData(WebPageProblem.TooBig, "Page is too big")]
    [InlineData(WebPageProblem.TimedOut, "Page took too long")]
    [InlineData(WebPageProblem.TooLong, "Page is too long")]
    public void ALimitHasItsOwnProblem(WebPageProblem which, string title) =>
        Assert.Equal(title, CreateProblems.Failed(new WebPageException(which), WebRequest).Title);

    [Fact]
    public async Task AFileOverTheLimitIsRefusedBeforeTheViewSeesIt()
    {
        string file = Path.Combine(Path.GetTempPath(), "lazypdf-" + Guid.NewGuid().ToString("N") + ".html");
        try
        {
            using (var stream = File.Create(file)) stream.SetLength(WebPageRules.MostBytes + 1);

            var error = await Assert.ThrowsAsync<WebPageException>(() => PdfMaker.MakeWebPageAsync(WebRequest with { Files = [file] }, CancellationToken.None));

            Assert.Equal(WebPageProblem.TooBig, error.Problem);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Theory]
    [InlineData("<img src=\"https://a.example/p.png\">", true)]
    [InlineData("<IMG SRC='//a.example/p.png'>", true)]
    [InlineData("<link rel=\"stylesheet\" href=\"http://a.example/s.css\">", true)]
    [InlineData("<style>body { background: url(https://a.example/b.png) }</style>", true)]
    [InlineData("<style>@import \"https://a.example/s.css\";</style>", true)]
    [InlineData("<script src=https://a.example/s.js></script>", true)]
    [InlineData("<img alt=\"a\" class=b SRC = \" HTTPS://a.example/p.png\">", true)]
    [InlineData("<a href=\"https://a.example/\">link</a>", false)]
    [InlineData("<img src=\"pic.png\">", false)]
    [InlineData("<p>see https://a.example/p.png</p>", false)]
    [InlineData("<img alt=\"x\"><p data-src=\"//a.example/\">", false)]
    [InlineData("<img xsrc=\"//a.example/p.png\">", false)]
    [InlineData("", false)]
    public void PartsFromTheInternetAreSpottedButLinksAreNot(string html, bool expected) => Assert.Equal(expected, WebPageRules.NamesRemoteParts(html));

    [Fact]
    public void AFileOfTagStartsIsReadInShortOrder()
    {
        string html = string.Concat(Enumerable.Repeat("<img ", 20_000)) + new string('x', 100_000) + "url(" + new string(' ', 100_000);
        var watch = System.Diagnostics.Stopwatch.StartNew();

        Assert.False(WebPageRules.NamesRemoteParts(html));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public Task AWebPageDroppedOnThePanelIsTheSourceAndNamesTheResult() => Sta.Run(() =>
    {
        var panel = new CreatePanel();
        Assert.Equal((int)CreateSource.Blank, panel.SourceBox.SelectedIndex);

        panel.TypedText.RaiseEvent(BatchDropTests.Drop(panel.TypedText, @"C:\x\Report 1.HTML"));

        Assert.Equal((int)CreateSource.WebPage, panel.SourceBox.SelectedIndex);
        Assert.True(panel.Action!.CanRun());
        var request = panel.Request()!;
        Assert.Equal("Report 1.pdf", request.Title);
        Assert.Equal([@"C:\x\Report 1.HTML"], request.Files);
        return Task.CompletedTask;
    });

    [Fact]
    public async Task CancelStopsAPageThatIsStillBeingPrinted()
    {
        string folder = Path.Combine(Path.GetTempPath(), "lazypdf-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        string file = Path.Combine(folder, "big.html");
        try
        {
            File.WriteAllText(file, "<table>" + string.Concat(Enumerable.Repeat("<tr><td>a</td><td>b</td></tr>", 400_000)) + "</table>");
            using var cancel = new CancellationTokenSource();
            var setup = new PdfPageSetup(PdfPaper.A4, PdfOrientation.Auto, 36);

            await Sta.Run(async () =>
            {
                cancel.CancelAfter(TimeSpan.FromSeconds(3));
                var watch = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    await WebPagePdf.RenderAsync(file, setup, cancel.Token);
                    Assert.Fail("The page was drawn before it could be cancelled.");
                }
                catch (WebViewMissingException)
                {
                }
                catch (OperationCanceledException)
                {
                    Assert.True(watch.Elapsed < TimeSpan.FromSeconds(30));
                }
            });
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}
