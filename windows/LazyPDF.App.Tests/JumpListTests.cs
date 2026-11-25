using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class JumpListTests
{
    [Fact]
    public void ForgettingAMissingFileDoesNotThrow()
    {
        var path = Path.Combine(Path.GetTempPath(), "lazypdf-gone", "missing.pdf");
        JumpLists.Remove(path);
        JumpLists.Remove(@"Z:\nowhere\x.pdf");
    }
}
