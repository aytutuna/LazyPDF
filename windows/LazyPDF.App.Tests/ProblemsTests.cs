using LazyPDF.App.Documents;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Problems.Tool: what a failed tool says depends on what went wrong.
public sealed class ProblemsTests
{
    [Fact]
    public void ADiskErrorSaysToCheckTheDisk() =>
        Assert.Contains("disk has room", Problems.Tool(new IOException(), "Split").Text);

    [Fact]
    public void AnythingElseKeepsTheGeneralText() =>
        Assert.Equal("Split could not be finished. If part of it was done, Undo takes it back.", Problems.Tool(new Exception(), "Split").Text);

    [Fact]
    public void ARestrictedFileSaysSo() =>
        Assert.Equal(Problems.Restricted(), Problems.Tool(new PdfPermissionException("restricted"), "Split"));

    [Fact]
    public void PlainNoAccessIsNotRestricted()
    {
        var problem = Problems.Tool(new UnauthorizedAccessException(), "Split");
        Assert.NotEqual(Problems.Restricted(), problem);
        Assert.Equal("No access", problem.Title);
    }

    [Fact]
    public void AMissingFileSaysSo() =>
        Assert.Equal("File not found", Problems.Tool(new FileNotFoundException(), "Split").Title);

    [Fact]
    public void ATruncatedStreamIsTheGeneralProblem() =>
        Assert.Equal("Split could not be finished. If part of it was done, Undo takes it back.", Problems.Tool(new EndOfStreamException(), "Split").Text);

    [Fact]
    public void AnUnreadableResultSaysItWasReadBack() =>
        Assert.Contains("read back", Problems.Tool(new PdfReadException(PdfReadProblem.Damaged, "x"), "Split").Text);
}
