using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by the Swift suite. Run with LAZYPDF_WRITE_GOLDEN=1 to write the output again.
public class WritersGoldenTests
{
    [Fact]
    public void WritersOutputIsTheGoldenFile()
    {
        byte[] font = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf"));
        Golden.Check("writers", "writers-output.txt", WritersGolden.Run(font, Golden.Input("writers", "writers-input.txt")));
    }
}
