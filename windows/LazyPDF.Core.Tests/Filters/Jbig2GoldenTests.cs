using System.Runtime.CompilerServices;
using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by the Jbig2 golden test of the Swift engine. The streams are made by the encoders of this project (Jbig2Samples);
// with LAZYPDF_WRITE_GOLDEN=1 the .bin files, the input and the output are written into Tests/Fixtures/golden/filters, and the
// Swift side only reads them. One line of input is "jbig2 <file> <globals> <flips> <length>"; the result is the page the filter
// returns: short results in hex, long ones as their length and an FNV-1a sum.
public class Jbig2GoldenTests
{
    private static string SourceFolder([CallerFilePath] string path = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, "..", "..", "..", "Tests", "Fixtures", "golden", "filters"));

    private static bool Writing => Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") == "1";

    private static string Folder => Writing ? SourceFolder() : Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "filters");

    private static IEnumerable<(string Name, byte[] Data)> Files() =>
        Jbig2Samples.All().Select(s => (s.Name, s.Data)).Append(("globals.bin", Jbig2Samples.Globals()));

    [Fact]
    public void OutputIsTheGoldenFile()
    {
        string input = Jbig2Samples.InputText();
        if (Writing)
        {
            foreach (var (name, data) in Files()) File.WriteAllBytes(Path.Combine(Folder, name), data);
            File.WriteAllText(Path.Combine(Folder, "jbig2-input.txt"), input, new UTF8Encoding(false));
        }
        Golden.Check("filters", "jbig2-output.txt", Run(input));
    }

    [Fact]
    public void FixturesAreWhatTheEncodersMake()
    {
        if (Writing) return;
        foreach (var (name, data) in Files()) Assert.True(data.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(Folder, name))), name);
        Assert.Equal(Jbig2Samples.InputText(), Golden.Input("filters", "jbig2-input.txt"));
    }

    [Fact]
    public void EverySampleDecodesToItsBitmap()
    {
        var globals = Jbig2Samples.Globals();
        foreach (var sample in Jbig2Samples.All())
        {
            var parameters = sample.Name == "with-globals.bin" ? Parameters(globals) : null;
            Assert.True(sample.Expected!.Packed().AsSpan().SequenceEqual(PdfFilters.Decode(sample.Data, new PdfName("JBIG2Decode"), parameters)), sample.Name);
        }
    }

    private static PdfDictionary Parameters(byte[] globals)
    {
        var parameters = new PdfDictionary();
        parameters["JBIG2Globals"] = new PdfStream(new PdfDictionary(), globals);
        return parameters;
    }

    private static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] words = line.Split(' ');
            output.Append("> ").Append(line).Append('\n').Append("< ").Append(Op(words[1..])).Append('\n');
        }
        return output.ToString();
    }

    // jbig2 <file> <globals> <flips> <length>
    private static string Op(string[] words)
    {
        try
        {
            byte[] data = File.ReadAllBytes(Path.Combine(Folder, words[0]));
            if (words[2] != "-")
            {
                foreach (string flip in words[2].Split(','))
                {
                    string[] parts = flip.Split(':');
                    data[int.Parse(parts[0])] ^= Convert.ToByte(parts[1], 16);
                }
            }
            if (words[3] != "-") data = data[..int.Parse(words[3])];
            var parameters = words[1] == "-" ? null : Parameters(File.ReadAllBytes(Path.Combine(Folder, words[1])));
            return Show(PdfFilters.Decode(data, new PdfName("JBIG2Decode"), parameters, PdfFilters.DefaultMaxSize));
        }
        catch (PdfReadException e)
        {
            string problem = e.Problem.ToString();
            return $"error {char.ToLowerInvariant(problem[0])}{problem[1..]}: {Golden.Escape(e.Message)}";
        }
    }

    private static string Show(byte[] data)
    {
        if (data.Length <= 64) return Convert.ToHexString(data);
        uint sum = 2166136261;
        foreach (byte b in data) sum = (sum ^ b) * 16777619;
        return $"length={data.Length} fnv={sum:x8}";
    }
}
