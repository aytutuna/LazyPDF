using Xunit;

namespace LazyPDF.App.Tests;

public sealed class HeldFilesTests
{
    private static InfoMessage Notice(string title) => new(title, "", false);

    [Fact]
    public void HeldFilesOpenWhenNoMessageIsShowing()
    {
        Assert.True(MainWindow.MayRelease(null, Notice("Before"), Notice("Result")));
    }

    [Fact]
    public void AMessageThatWasUpBeforeTheHoldDoesNotKeepThemWaiting()
    {
        var before = Notice("Before");

        Assert.True(MainWindow.MayRelease(before, before, null));
    }

    [Fact]
    public void TheResultOfTheJobIsNotWipedTheMomentItEnds()
    {
        Assert.False(MainWindow.MayRelease(Notice("Result"), Notice("Before"), null));
        var result = Notice("Result");
        Assert.False(MainWindow.MayRelease(result, null, result));
    }

    [Fact]
    public void AReplacedMessageReleasesThem()
    {
        Assert.True(MainWindow.MayRelease(Notice("Other file"), null, Notice("Result")));
    }
}
