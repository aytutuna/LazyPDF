using LazyPDF.App.Viewer;
using System.Windows;
using Xunit;

namespace LazyPDF.App.Tests;

// Back and Forward over the jumps a reader made.
public sealed class PageHistoryTests
{
    private static PagePoint At(int page, double y = 0) => new(page, new Point(0, y));

    [Fact]
    public void ANewHistoryGoesNowhere()
    {
        var history = new PageHistory();

        Assert.False(history.CanGoBack);
        Assert.False(history.CanGoForward);
        Assert.Null(history.Back(At(3)));
        Assert.Null(history.Forward(At(3)));
    }

    [Fact]
    public void BackReturnsToThePlaceJumpedFromAndForwardComesAgain()
    {
        var history = new PageHistory();
        history.Jump(At(0, 300), At(10));

        Assert.Equal(At(0, 300), history.Back(At(10)));
        Assert.True(history.CanGoForward);
        Assert.Equal(At(10), history.Forward(At(0, 300)));
        Assert.False(history.CanGoForward);
    }

    [Fact]
    public void JumpSaysWhetherItMadeAnEntry()
    {
        var history = new PageHistory();

        Assert.False(history.Jump(At(2, 100), At(2, 120)));
        Assert.False(history.CanGoBack);
        Assert.True(history.Jump(At(2, 100), At(2, 400)));
        Assert.True(history.CanGoBack);
    }

    [Fact]
    public void BackWalksThroughSeveralJumpsInReverse()
    {
        var history = new PageHistory();
        history.Jump(At(0), At(5));
        history.Jump(At(5), At(9));

        Assert.Equal(At(5), history.Back(At(9)));
        Assert.Equal(At(0), history.Back(At(5)));
        Assert.Null(history.Back(At(0)));
    }

    [Fact]
    public void ANewJumpAfterGoingBackForgetsTheForwardPlaces()
    {
        var history = new PageHistory();
        history.Jump(At(0), At(5));
        history.Back(At(5));

        history.Jump(At(0), At(7));

        Assert.False(history.CanGoForward);
        Assert.Equal(At(0), history.Back(At(7)));
    }

    [Fact]
    public void OnARotatedViewTheAcrossAxisIsTheOneThatCounts()
    {
        var history = new PageHistory();
        var from = new PagePoint(1, new Point(100, 100));

        Assert.False(history.Jump(from, new PagePoint(1, new Point(110, 400)), 90));
        Assert.True(history.Jump(from, new PagePoint(1, new Point(300, 110)), 90));
        Assert.False(history.Jump(from, new PagePoint(1, new Point(110, 100)), 0));
    }

    [Fact]
    public void AJumpWithinFiftyPointsOfTheSamePageIsNotAJump()
    {
        var history = new PageHistory();

        history.Jump(At(4, 100), At(4, 149));

        Assert.False(history.CanGoBack);
    }

    [Fact]
    public void AFarJumpOnTheSamePageIsAJump()
    {
        var history = new PageHistory();

        history.Jump(At(4, 100), At(4, 400));

        Assert.Equal(At(4, 100), history.Back(At(4, 400)));
    }

    [Fact]
    public void OnlyTheLastHundredAreKept()
    {
        var history = new PageHistory();
        for (int i = 0; i < 150; i++) history.Jump(At(i), At(i + 1));

        int count = 0;
        var place = At(150);
        while (history.Back(place) is { } previous)
        {
            place = previous;
            count++;
        }

        Assert.Equal(100, count);
    }

    [Fact]
    public void ClearingForgetsEverything()
    {
        var history = new PageHistory();
        history.Jump(At(0), At(5));

        history.Clear();

        Assert.False(history.CanGoBack);
    }
}
