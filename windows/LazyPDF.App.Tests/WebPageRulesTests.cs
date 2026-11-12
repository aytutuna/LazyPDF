using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Create;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What a web page file may load, and the paper it is drawn on. The web view itself needs the runtime and a window.
[Collection("Application")]
public sealed class WebPageRulesTests
{
    private const string Folder = @"C:\Docs\Site";

    [Theory]
    [InlineData("file:///C:/Docs/Site/style.css")]
    [InlineData("file:///C:/Docs/Site/img/a%20b.png")]
    [InlineData("file:///c:/docs/site/Index.HTML")]
    [InlineData("data:image/png;base64,AAAA")]
    [InlineData("about:blank")]
    public void LocalResourcesBesideThePageLoad(string address) => Assert.True(WebPageRules.IsAllowed(address, Folder));

    [Theory]
    [InlineData("http://example.com/a.css")]
    [InlineData("https://example.com/")]
    [InlineData("ftp://example.com/a.png")]
    [InlineData("ws://example.com/")]
    [InlineData("blob:https://example.com/1")]
    [InlineData("file:///C:/Docs/Other/secret.txt")]
    [InlineData("file:///C:/Docs/SiteTwo/a.css")]
    [InlineData("file:///C:/Docs/Site/../Other/a.css")]
    [InlineData("file:///C:/Docs/Site/%2e%2e/Other/a.css")]
    [InlineData("file://server/share/a.css")]
    [InlineData("//example.com/a.css")]
    [InlineData("not an address")]
    [InlineData("")]
    public void EverythingElseIsBlocked(string address) => Assert.False(WebPageRules.IsAllowed(address, Folder));

    [Fact]
    public void AFolderWithATrailingSlashIsTheSameFolder() => Assert.True(WebPageRules.IsAllowed("file:///C:/Docs/Site/a.css", Folder + @"\"));

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
    public void PaperIsInchesAndFollowsTheOrientation(PdfPaper paper, PdfOrientation orientation, double width, double height)
    {
        var layout = WebPageRules.Layout(new PdfPageSetup(paper, orientation, 36));

        Assert.Equal(width, layout.Width, 4);
        Assert.Equal(height, layout.Height, 4);
        Assert.Equal(0.5, layout.Margin, 6);
    }

    [Fact]
    public void ANoMarginIsAllowed() => Assert.Equal(0, WebPageRules.Layout(new PdfPageSetup(PdfPaper.A4, PdfOrientation.Auto, 0)).Margin);

    [Fact]
    public void AMarginThatLeavesNoRoomIsRefused() =>
        Assert.Throws<ArgumentException>(() => WebPageRules.Layout(new PdfPageSetup(PdfPaper.Letter, PdfOrientation.Landscape, 306)));

    [Fact]
    public void ARuntimeThatIsMissingIsSaidPlainly()
    {
        var problem = CreateProblems.Failed(new WebViewMissingException(), CreateSource.WebPage);

        Assert.Equal("Web pages need WebView2", problem.Title);
        Assert.Contains("WebView2 Runtime", problem.Text);
    }

    [Fact]
    public void APageThatCannotBeDrawnIsNotCalledAPicture()
    {
        var problem = CreateProblems.Failed(new IOException(), CreateSource.WebPage);

        Assert.Equal("Web page cannot be drawn", problem.Title);
    }

    [Fact]
    public Task AWebPageDroppedOnThePanelIsTheSourceAndNamesTheResult() => Sta.Run(() =>
    {
        var panel = new CreatePanel();
        Assert.False(panel.Action!.CanRun());

        panel.TypedText.RaiseEvent(BatchDropTests.Drop(panel.TypedText, @"C:\x\Report 1.HTML"));

        Assert.Equal((int)CreateSource.WebPage, panel.SourceBox.SelectedIndex);
        Assert.True(panel.Action!.CanRun());
        var request = panel.Request()!;
        Assert.Equal("Report 1.pdf", request.Title);
        Assert.Equal([@"C:\x\Report 1.HTML"], request.Files);
        return Task.CompletedTask;
    });
}
