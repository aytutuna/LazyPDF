using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Fonts/Programs/ProgramsGoldenTests.swift. The font all dumps read is
// Tests/Fixtures/golden/programs/synthetic.ttf, made by TrueTypeBuilder. Run with LAZYPDF_WRITE_GOLDEN=1 to
// write the font and the outputs again; Swift only reads them.
public class ProgramsGoldenTests
{
    private static string Folder(string name)
    {
        var here = Path.GetDirectoryName(ThisFile())!;
        return Path.GetFullPath(Path.Combine(here, "..", "..", "..", "..", "Tests", "Fixtures", "golden", "programs", name));
    }

    private static string ThisFile([System.Runtime.CompilerServices.CallerFilePath] string path = "") => path;

    private static byte[] Synthetic()
    {
        var built = TrueTypeBuilder.Build();
        if (Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") != "1")
            return File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "programs", "synthetic.ttf"));
        Directory.CreateDirectory(Path.GetDirectoryName(Folder("synthetic.ttf"))!);
        File.WriteAllBytes(Folder("synthetic.ttf"), built);
        return built;
    }

    [Fact]
    public void SyntheticFontIsTheBuilderOutput() =>
        Assert.Equal(TrueTypeBuilder.Build(), File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "programs", "synthetic.ttf")));

    [Fact]
    public void StandardNamesAreTheGoldenFile() =>
        Golden.Check("programs", "standard-names-output.txt", ProgramsGolden.StandardNamesDump());

    [Fact]
    public void TrueTypeIsTheGoldenFile() =>
        Golden.Check("programs", "truetype-output.txt", ProgramsGolden.TrueType(Synthetic()));

    [Fact]
    public void SubsetIsTheGoldenFile() =>
        Golden.Check("programs", "subset-output.txt", ProgramsGolden.Subset(Synthetic()));

    [Fact]
    public void EmbeddedFontIsTheGoldenFile() =>
        Golden.Check("programs", "embedded-output.txt", ProgramsGolden.Embedded(Synthetic()));

    [Fact]
    public void CffIsTheGoldenFile() =>
        Golden.Check("programs", "cff-output.txt", ProgramsGolden.Cff(Golden.Input("programs", "cff-input.txt")));

    [Fact]
    public void Type1IsTheGoldenFile() =>
        Golden.Check("programs", "type1-output.txt", ProgramsGolden.Type1());

    [Fact]
    public void DamagedFontsAreTheGoldenFile() =>
        Golden.Check("programs", "damaged-output.txt", ProgramsGolden.Damaged(Synthetic()));
}
