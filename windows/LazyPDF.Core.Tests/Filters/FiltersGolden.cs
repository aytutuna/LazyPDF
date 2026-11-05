using System.Runtime.CompilerServices;
using System.Text;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Filters/FiltersGolden.swift. One line of input is "<op> <words>"; the result is
// what the filters made of the bytes: short results in hex, long ones as their length and an FNV-1a sum. Bytes are
// escaped, filters are names joined by commas and parameters are Key=value pairs joined by commas, the value in PDF
// syntax; "-" is none. A blocks case builds its own deflate stream.
internal static class FiltersGolden
{
    private static string SourceFolder([CallerFilePath] string path = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, "..", "..", "..", "Tests", "Fixtures", "golden", "filters"));

    private static string Folder => Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") == "1"
        ? SourceFolder()
        : Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "filters");

    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] words = line.Split(' ');
            output.Append("> ").Append(line).Append('\n').Append("< ").Append(Op(words[0], words[1..])).Append('\n');
        }
        return output.ToString();
    }

    private static string Op(string op, string[] words)
    {
        try
        {
            switch (op)
            {
                case "decode":
                    return Show(PdfFilters.Decode(Bytes(words[2]), Filter(words[0]), Parameters(words[1]), PdfFilters.DefaultMaxSize));
                case "strict":
                    return Show(PdfFilters.Decode(Bytes(words[0]), FilterFixtures.Parse("/FlateDecode"), null, PdfFilters.DefaultMaxSize, strict: true));
                case "inflate":
                    return Show(PdfFilters.Inflate(Bytes(words[0])));
                case "predict":
                    return Show(PdfFilters.Predict(Bytes(words[1]), (PdfDictionary?)Parameters(words[0])));
                case "codec":
                    var decoded = PdfFilters.DecodeToCodec(Bytes(words[2]), Filter(words[0]), Parameters(words[1]));
                    return $"codec={decoded.Codec ?? "-"} parameters={(decoded.Parameters is null ? "-" : "dictionary")} data={Show(decoded.Data)}";
                case "file":
                    return Run(words);
                case "blocks":
                    return Show(PdfFilters.Decode(Blocks(int.Parse(words[0]), int.Parse(words[1]), words[2]), FilterFixtures.Parse("/FlateDecode"), null,
                        PdfFilters.DefaultMaxSize, strict: words[3] == "1"));
                default:
                    throw new InvalidOperationException($"No op \"{op}\".");
            }
        }
        catch (PdfReadException e)
        {
            string problem = e.Problem.ToString();
            return $"error {char.ToLowerInvariant(problem[0])}{problem[1..]}: {Golden.Escape(e.Message)}";
        }
    }

    // file <filters> <parameters> <name> <strict 0|1> <flips> <length>
    private static string Run(string[] words)
    {
        byte[] data = File.ReadAllBytes(Path.Combine(Folder, words[2]));
        if (words[4] != "-")
            foreach (string flip in words[4].Split(','))
            {
                string[] parts = flip.Split(':');
                data[int.Parse(parts[0])] ^= Convert.ToByte(parts[1], 16);
            }
        if (words[5] != "-") data = data[..int.Parse(words[5])];
        return Show(PdfFilters.Decode(data, Filter(words[0]), Parameters(words[1]), PdfFilters.DefaultMaxSize, strict: words[3] == "1"));
    }

    // A raw deflate stream: one fixed block of literals and runs of 258 at distance 1, then the tail. The codes are
    // the fixed ones of RFC 1951 3.2.6.
    private static byte[] Blocks(int literals, int matches, string tail)
    {
        var bits = new List<bool>();
        void Put(int value, int count) { for (int i = 0; i < count; i++) bits.Add((value >> i & 1) != 0); }
        void Code(int code, int count) { for (int i = count - 1; i >= 0; i--) bits.Add((code >> i & 1) != 0); }
        Put(0, 1);
        Put(1, 2);
        for (int i = 0; i < literals; i++) Code(0x30 + (i * 7 + 3) % 100, 8);
        for (int i = 0; i < matches; i++)
        {
            Code(0xC5, 8);
            Code(0, 5);
        }
        if (tail != "cut") Code(0, 7);
        var extra = new List<byte>();
        switch (tail)
        {
            case "end":
                Put(1, 1);
                Put(1, 2);
                Code(0, 7);
                break;
            case "bad":
                Put(1, 1);
                Put(3, 2);
                break;
            case "badlen":
                Put(0, 3);
                extra.AddRange([1, 0, 0, 0, (byte)'x']);
                break;
        }
        while (bits.Count % 8 != 0) bits.Add(false);
        var bytes = new List<byte>();
        for (int i = 0; i < bits.Count; i += 8)
        {
            int b = 0;
            for (int j = 0; j < 8; j++) if (bits[i + j]) b |= 1 << j;
            bytes.Add((byte)b);
        }
        bytes.AddRange(extra);
        return [.. bytes];
    }

    private static byte[] Bytes(string word) => word == "-" ? [] : Golden.Unescape(word);

    private static PdfObject? Filter(string word) =>
        word == "-" ? null : FilterFixtures.Parse(word.Contains(',') ? "[" + string.Join(" ", word.Split(',').Select(n => "/" + n)) + "]" : "/" + word);

    private static PdfObject? Parameters(string word) =>
        word == "-" ? null : FilterFixtures.Parse("<< " + string.Join(" ", word.Split(',').Select(p => "/" + p.Replace("=", " "))) + " >>");

    private static string Show(byte[] data)
    {
        if (data.Length <= 64) return Convert.ToHexString(data);
        uint sum = 2166136261;
        foreach (byte b in data) sum = (sum ^ b) * 16777619;
        return $"length={data.Length} fnv={sum:x8}";
    }
}
