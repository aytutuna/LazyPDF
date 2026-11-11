using LazyPDF.App.Documents;
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
        Assert.Equal(Problems.Restricted(), Problems.Tool(new UnauthorizedAccessException(), "Split"));
}
