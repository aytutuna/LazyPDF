using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class DestinationAimTests
{
    [Theory]
    [InlineData(DestinationFit.Fit)]
    [InlineData(DestinationFit.FitB)]
    [InlineData(DestinationFit.FitV)]
    [InlineData(DestinationFit.Xyz)]
    public void AViewWithoutATopOrLeftDoesNotAim(DestinationFit fit)
    {
        var destination = new PdfDestination(0, fit);

        Assert.False(PageViewer.AimsAtTop(destination, 0, 0));
        Assert.False(PageViewer.AimsAtTop(destination, 0, 270));
    }

    [Fact]
    public void ATopAimsWhileTheViewRunsAlongThePage()
    {
        var destination = new PdfDestination(0, DestinationFit.FitH, Top: 700);

        Assert.True(PageViewer.AimsAtTop(destination, 0, 0));
        Assert.True(PageViewer.AimsAtTop(destination, 0, 180));
        Assert.False(PageViewer.AimsAtTop(destination, 0, 270));
    }

    [Fact]
    public void ALeftAimsWhenTheViewIsTurnedAcross()
    {
        var destination = new PdfDestination(0, DestinationFit.FitV, Left: 40);

        Assert.False(PageViewer.AimsAtTop(destination, 0, 0));
        Assert.True(PageViewer.AimsAtTop(destination, 0, 270));
        Assert.True(PageViewer.AimsAtTop(destination, 90, 0));
        Assert.False(PageViewer.AimsAtTop(destination, 90, 90));
    }

    [Fact]
    public void AnXyzNeedsTheCoordinateThatRunsDownTheScreen()
    {
        var destination = new PdfDestination(0, DestinationFit.Xyz, Left: 40);

        Assert.False(PageViewer.AimsAtTop(destination, 0, 0));
        Assert.True(PageViewer.AimsAtTop(destination, 0, 90));
    }
}
