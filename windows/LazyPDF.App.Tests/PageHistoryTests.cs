using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// Back and Forward over the jumps a reader made.
public sealed class PageHistoryTests
{
    [Fact]
    public void ANewHistoryGoesNowhere()
    {
        var history = new PageHistory();

        Assert.False(history.CanGoBack);
        Assert.False(history.CanGoForward);
        Assert.Null(history.Back(3));
        Assert.Null(history.Forward(3));
    }

    [Fact]
    public void BackReturnsToThePageJumpedFromAndForwardComesAgain()
    {
        var history = new PageHistory();
        history.Jump(0, 10);

        Assert.Equal(0, history.Back(10));
        Assert.True(history.CanGoForward);
        Assert.Equal(10, history.Forward(0));
        Assert.False(history.CanGoForward);
    }

    [Fact]
    public void BackWalksThroughSeveralJumpsInReverse()
    {
        var history = new PageHistory();
        history.Jump(0, 5);
        history.Jump(5, 9);

        Assert.Equal(5, history.Back(9));
        Assert.Equal(0, history.Back(5));
        Assert.Null(history.Back(0));
    }

    [Fact]
    public void ANewJumpAfterGoingBackForgetsTheForwardPages()
    {
        var history = new PageHistory();
        history.Jump(0, 5);
        history.Back(5);

        history.Jump(0, 7);

        Assert.False(history.CanGoForward);
        Assert.Equal(0, history.Back(7));
    }

    [Fact]
    public void AJumpToTheSamePageIsNotAJump()
    {
        var history = new PageHistory();

        history.Jump(4, 4);

        Assert.False(history.CanGoBack);
    }

    [Fact]
    public void OnlyTheLastHundredAreKept()
    {
        var history = new PageHistory();
        for (int i = 0; i < 150; i++) history.Jump(i, i + 1);

        int count = 0;
        int page = 150;
        while (history.Back(page) is { } previous)
        {
            page = previous;
            count++;
        }

        Assert.Equal(100, count);
    }

    [Fact]
    public void ClearingForgetsEverything()
    {
        var history = new PageHistory();
        history.Jump(0, 5);

        history.Clear();

        Assert.False(history.CanGoBack);
    }
}
