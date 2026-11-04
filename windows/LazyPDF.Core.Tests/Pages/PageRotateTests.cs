using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageRotateTests
{
    [Fact]
    public void RotationAddsUpAndStaysAMultipleOf90()
    {
        var document = PageTestFiles.Open(3);
        PageOperations.Rotate(document, [0, 2], 90);
        PageOperations.Rotate(document, [0], 270);
        PageOperations.Rotate(document, [2], 180);
        PageOperations.Rotate(document, [1], -90);
        Assert.Equal([0, 270, 270], document.Pages.Select(p => p.Rotate));
        Assert.All(document.Pages, p => Assert.Equal(0, ((PdfNumber)p.Dictionary["Rotate"]!).Integer % 90));
    }

    [Fact]
    public void RotationBuildsOnWhatThePageInherits()
    {
        var document = PageTestFiles.Open(2, rootExtra: "/Rotate 90");
        PageOperations.Rotate(document, [1], 90);
        Assert.Equal([90, 180], document.Pages.Select(p => p.Rotate));
    }

    [Fact]
    public void ARepeatedPageTurnsOnce()
    {
        var document = PageTestFiles.Open(1);
        PageOperations.Rotate(document, [0, 0], 90);
        Assert.Equal(90, document.Pages[0].Rotate);
    }

    [Theory]
    [InlineData(45)]
    [InlineData(100)]
    public void AnAngleThatIsNotAQuarterTurnIsRefused(int degrees)
    {
        var document = PageTestFiles.Open(1);
        Assert.Throws<ArgumentException>(() => PageOperations.Rotate(document, [0], degrees));
    }

    [Fact]
    public void APageThatIsNotThereIsRefusedBeforeAnythingChanges()
    {
        var document = PageTestFiles.Open(2);
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.Rotate(document, [0, 2], 90));
        Assert.Equal(0, document.Pages[0].Rotate);
    }

    [Fact]
    public void RotationSurvivesACommitAndAnUndo()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(2));
        PageOperations.Rotate(session.Document, [1], 90);
        var reopened = PageTestFiles.Commit(session, "Rotate");
        Assert.Equal([0, 90], reopened.Pages.Select(p => p.Rotate));
        Assert.True(session.Undo());
        Assert.Equal([0, 0], session.Document.Pages.Select(p => p.Rotate));
    }
}
