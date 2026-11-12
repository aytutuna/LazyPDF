using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OfficeFontSourceTests
{
    // Mirrored by Tests/LazyPDFKitTests/Office/OfficeFontSourceTests.swift. The input format is at the top of chain-input.txt.
    private sealed class FakeSource(IEnumerable<string> families) : IFontSource
    {
        private readonly HashSet<string> _families = new(families, StringComparer.OrdinalIgnoreCase);

        public FontFile? Find(string family, FontStyles style) =>
            _families.Contains(family) ? new FontFile(Encoding.UTF8.GetBytes($"{family}/{(int)style}")) : null;
    }

    private static IFontSource? Source(string list) => list == "-" ? null : new FakeSource(list.Split(','));

    private static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] w = line.Split('|');
            string family = Encoding.UTF8.GetString(Golden.Unescape(w[2]));
            var style = w[3] switch { "b" => FontStyles.Bold, "i" => FontStyles.Italic, "bi" => FontStyles.Bold | FontStyles.Italic, _ => FontStyles.Regular };
            var found = new OfficeFontSource(Source(w[0]), Source(w[1])).Find(family, style);
            output.Append("> ").Append(line).Append('\n');
            output.Append("< ").Append(found is null ? "none" : Encoding.UTF8.GetString(found.Data)).Append('\n');
        }
        return output.ToString();
    }

    [Fact]
    public void GoldenFile()
    {
        Golden.Check("office-fonts", "chain-output.txt", Run(Golden.Input("office-fonts", "chain-input.txt")));
    }

    [Fact]
    public void InstalledFontComesBeforeTheBundledOne()
    {
        var found = new OfficeFontSource(new FakeSource(["Calibri"]), new FakeSource(["Carlito"])).Find("Calibri", FontStyles.Regular);
        Assert.Equal("Calibri/0", Encoding.UTF8.GetString(found!.Data));
    }

    private sealed class CarlitoOnly : IFontSource
    {
        public int Reads { get; private set; }

        public FontFile? Find(string family, FontStyles style)
        {
            if (family != "Carlito" || style != FontStyles.Regular) return null;
            Reads++;
            return new FontFile(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fonts", "Carlito-Regular.ttf")));
        }
    }

    [Fact]
    public void UnknownNamesShareOneFontFileAndOneFace()
    {
        var bundled = new CarlitoOnly();
        var fonts = new LayoutFonts(new OfficeFontSource(null, bundled));
        var first = fonts.Find("f0", FontStyles.Regular);
        Assert.NotNull(first);
        for (int i = 1; i < 2000; i++) Assert.Same(first, fonts.Find("f" + i, FontStyles.Regular));
        Assert.Equal(1, bundled.Reads);
    }

    // The widths of the bundled fonts are what makes them stand in for Word's: A in units of 2048 per em as in the
    // fonts they copy (Arial 1366, Times New Roman 1479, Courier New 1229, Calibri 1185).
    [Theory]
    [InlineData("Carlito", "Carlito-Regular.ttf", 1185)]
    [InlineData("Liberation Sans", "LiberationSans-Regular.ttf", 1366)]
    [InlineData("Liberation Serif", "LiberationSerif-Regular.ttf", 1479)]
    [InlineData("Liberation Mono", "LiberationMono-Regular.ttf", 1229)]
    public void BundledFontsKeepTheMetricsOfWordsFonts(string family, string file, int advanceOfA)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Fonts", file);
        var font = TrueTypeFont.TryParse(File.ReadAllBytes(path), 0);
        Assert.NotNull(font);
        Assert.Equal(2048, font.UnitsPerEm);
        Assert.Equal(advanceOfA, font.GetAdvance(font.GlyphForCodePoint('A')));
        Assert.True(font.EmbeddingAllowed && font.SubsettingAllowed, family);
    }
}
