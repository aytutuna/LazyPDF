using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by the Swift suite. Run with LAZYPDF_WRITE_GOLDEN=1 to write the font and the output again.
public class ShapingGoldenTests
{
    private static string FontPath([System.Runtime.CompilerServices.CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "..", "Tests", "Fixtures", "golden", "shaping", "script.ttf"));

    private static byte[] Font()
    {
        var built = TrueTypeBuilder.BuildScript();
        if (Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") != "1")
            return File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf"));
        Directory.CreateDirectory(Path.GetDirectoryName(FontPath())!);
        File.WriteAllBytes(FontPath(), built);
        return built;
    }

    [Fact]
    public void TheFontIsTheBuilderOutput() =>
        Assert.Equal(TrueTypeBuilder.BuildScript(), File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf")));

    [Fact]
    public void LinesAreTheGoldenFile() =>
        Golden.Check("shaping", "lines-output.txt", ShapingGolden.Dump(Font(), Golden.Input("shaping", "lines-input.txt")));
}
