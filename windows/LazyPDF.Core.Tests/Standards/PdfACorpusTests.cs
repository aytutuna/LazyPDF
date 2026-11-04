using System.Diagnostics;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Validates every file in the list LAZYPDF_CORPUS names (one path per line), converts each to PDF/A-2b
// and validates the result; does nothing otherwise. Only counts are printed.
public class PdfACorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileIsCheckedConvertedAndCheckedAgain()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, clean = 0, converted = 0, refused = 0, failed = 0, claiming = 0, claimingClean = 0;
        var claimed = new SortedDictionary<string, int>();
        var before = new SortedDictionary<string, int>();
        var after = new SortedDictionary<string, int>();
        var refusals = new SortedDictionary<string, int>();
        var left = new SortedDictionary<string, int>();
        var crashes = new List<string>();
        var clock = Stopwatch.StartNew();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            byte[] bytes = File.ReadAllBytes(path);
            try
            {
                using var document = PdfDocument.Open(bytes);
                files++;
                if (ClaimedLevel(document) is { } own)
                {
                    claiming++;
                    var claim = PdfAValidator.Validate(document, own);
                    if (claim.IsValid) claimingClean++;
                    foreach (string clause in claim.Issues.Select(i => $"{own} {i.Clause}").Distinct()) claimed[clause] = claimed.GetValueOrDefault(clause) + 1;
                }
                var report = PdfAValidator.Validate(document, PdfALevel.A2b);
                if (report.IsValid) clean++;
                foreach (string clause in report.Issues.Select(i => i.Clause).Distinct()) before[clause] = before.GetValueOrDefault(clause) + 1;

                var result = new PdfAConverter(new SystemFonts()).Convert(bytes, PdfALevel.A2b, new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
                if (result.Bytes is null)
                {
                    refused++;
                    refusals[result.Refusal!] = refusals.GetValueOrDefault(result.Refusal!) + 1;
                    continue;
                }
                using var again = PdfDocument.Open(result.Bytes);
                var remaining = PdfAValidator.Validate(again, PdfALevel.A2b);
                if (remaining.IsValid) converted++;
                else failed++;
                foreach (string clause in remaining.Issues.Select(i => i.Clause).Distinct()) after[clause] = after.GetValueOrDefault(clause) + 1;
                foreach (string message in remaining.Issues.Select(i => i.Clause + " " + i.Message).Distinct()) left[message] = left.GetValueOrDefault(message) + 1;
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                crashes.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"{files} files in {clock.Elapsed.TotalSeconds:0} s: {clean} already clean for PDF/A-2b, {converted} converted clean, {failed} converted with rules left, {refused} refused");
        output.WriteLine($"{claiming} files claim a PDF/A level, {claimingClean} of them pass it; clauses broken by those that claim: " + string.Join(", ", claimed.Select(p => $"{p.Key}={p.Value}")));
        output.WriteLine("files breaking each clause before: " + string.Join(", ", before.Select(p => $"{p.Key}={p.Value}")));
        output.WriteLine("files breaking each clause after: " + string.Join(", ", after.Select(p => $"{p.Key}={p.Value}")));
        output.WriteLine("what is left: " + string.Join("; ", left.Select(p => $"{p.Key}={p.Value}")));
        output.WriteLine("refusals: " + string.Join("; ", refusals.Select(p => $"{p.Key}={p.Value}")));
        foreach (var level in new[] { PdfALevel.A1b, PdfALevel.A4 }) output.WriteLine(Summary(level, list, crashes));
        Assert.True(crashes.Count == 0, string.Join("\n", crashes.Distinct().Take(10)));
    }

    private static string Summary(PdfALevel level, string list, List<string> crashes)
    {
        int clean = 0, left = 0, refused = 0;
        var converter = new PdfAConverter(new SystemFonts());
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            try
            {
                var result = converter.Convert(File.ReadAllBytes(path), level, new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
                if (result.Bytes is null) refused++;
                else if (result.Remaining.Count == 0) clean++;
                else left++;
            }
            catch (Exception e)
            {
                crashes.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        return $"{level.Name()}: {clean} converted clean, {left} with rules left, {refused} refused";
    }

    private static PdfALevel? ClaimedLevel(PdfDocument document) => (document.PdfAPart, document.PdfAConformance) switch
    {
        (1, _) => PdfALevel.A1b,
        (2, "U") => PdfALevel.A2u,
        (2, _) => PdfALevel.A2b,
        (3, "U") => PdfALevel.A3u,
        (3, _) => PdfALevel.A3b,
        (4, _) => PdfALevel.A4,
        _ => null,
    };
}
