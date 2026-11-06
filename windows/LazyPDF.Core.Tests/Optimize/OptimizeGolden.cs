using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Optimize/OptimizeGolden.swift. One line of input is "<op> <argument>":
//   linearize <pages>    LinearizerKit.Make(pages) saved by SaveLinearized, byte for byte, with the second string of /ID set to zeros (it holds nothing compressed)
//   audit dirty          the space audit of SanitizeKit.Dirty()
//   scan dirty           the sanitizer's findings
//   sanitize dirty       what a default run removed and kept
//   optimize <preset>    the steps and notes of a run on Dirty (counts only: deflate output differs between implementations)
internal static class OptimizeGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] words = line.Split(' ');
            output.Append("> ").Append(line).Append('\n');
            foreach (string result in Op(words[0], words[1])) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static string Findings(IReadOnlyList<SanitizeFinding> findings) => string.Join(" ", findings.Select(f => $"{f.Item}={f.Count}"));

    private static IEnumerable<string> Op(string op, string argument)
    {
        switch (op)
        {
            case "linearize":
                using (var source = PdfDocument.Open(LinearizerKit.Make(int.Parse(argument))))
                {
                    // The second string of /ID is random; it is set to zeros.
                    string text = Regex.Replace(Encoding.Latin1.GetString(source.SaveLinearized()), @"(/ID \[<[0-9A-F]{32}> )<[0-9A-F]{32}>", "$1<" + new string('0', 32) + ">");
                    return [Golden.Escape(text)];
                }
            case "audit":
                using (var document = PdfDocument.Open(SanitizeKit.Dirty()))
                {
                    var audit = new PdfOptimizer(document).Audit();
                    return [$"size {audit.FileSize}", .. Enum.GetValues<SpaceKind>().Select(k => $"{k} {audit.Of(k)}")];
                }
            case "scan":
                using (var document = PdfDocument.Open(SanitizeKit.Dirty()))
                {
                    return [Findings(new PdfSanitizer(document).Scan())];
                }
            case "sanitize":
                using (var document = PdfDocument.Open(SanitizeKit.Dirty()))
                {
                    var result = new PdfSanitizer(document).Run(new SanitizeOptions());
                    return [$"removed {Findings(result.Removed)}", $"kept {Findings(result.Kept)}"];
                }
            default:
                using (var document = PdfDocument.Open(SanitizeKit.Dirty()))
                {
                    var preset = argument switch { "small" => OptimizePreset.Small, "balanced" => OptimizePreset.Balanced, _ => OptimizePreset.HighQuality };
                    var result = new PdfOptimizer(document).Run(OptimizeOptions.For(preset));
                    return [string.Join(" ", result.Steps.Select(s => $"{s.Kind}={s.Count}")), $"notes {result.Notes.Count}"];
                }
        }
    }
}
