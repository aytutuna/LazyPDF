using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Optimises every file in the list LAZYPDF_CORPUS names (one path per line) on each preset and
// cleans it once, then reopens the result. Does nothing without the variable; only counts are printed.
public class CorpusOptimizeTests(ITestOutputHelper output)
{
    private const int MaxPages = 300;
    private const long MaxBytes = 60L << 20;
    private const int TextPages = 12;

    private static string Text(PdfDocument document)
    {
        var cache = new TextCache(document);
        return string.Join("\f", Enumerable.Range(0, Math.Min(TextPages, document.Pages.Count)).Select(i => cache.Get(i).Text));
    }

    [Fact]
    public void EveryFileShrinksOnEachPresetAndKeepsItsTextAndPages()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        var presets = Enum.GetValues<OptimizePreset>();
        var plainTotal = 0L;
        var optimizedTotal = presets.ToDictionary(p => p, _ => 0L);
        var sanitizedTotal = 0L;
        var smallWithoutCodec = 0L;
        int files = 0, done = 0, skipped = 0, sanitized = 0, pigReads = 0, layerFiles = 0;
        var failures = new List<string>();
        var codec = new OptimizeFakeCodec();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            try
            {
                using var document = PdfDocument.Open(path);
                if (document.IsSigned || document.Pages.Count == 0 || document.Pages.Count > MaxPages || document.Length > MaxBytes)
                {
                    skipped++;
                    continue;
                }
                string text = Text(document);
                int plain = document.SaveRewrite().Length;
                plainTotal += plain;
                foreach (var preset in presets)
                {
                    var result = new PdfOptimizer(document, codec).Run(OptimizeOptions.For(preset));
                    optimizedTotal[preset] += result.SizeAfter;
                    if (result.SizeAfter > plain) failures.Add($"{files}: {preset} larger than a plain rewrite");
                    using var reopened = PdfDocument.Open(result.Bytes);
                    if (reopened.Pages.Count != document.Pages.Count) failures.Add($"{files}: {preset} page count");
                    else if (Text(reopened) != text) failures.Add($"{files}: {preset} text");
                    if (preset == OptimizePreset.Small)
                    {
                        smallWithoutCodec += new PdfOptimizer(document).Run(OptimizeOptions.For(preset)).SizeAfter;
                        try
                        {
                            using var pig = UglyToad.PdfPig.PdfDocument.Open(result.Bytes);
                            pig.GetPage(1);
                            pigReads++;
                        }
                        catch (Exception)
                        {
                        }
                    }
                }

                var clean = new PdfSanitizer(document).Run(new SanitizeOptions());
                sanitizedTotal += clean.SizeAfter;
                using var cleaned = PdfDocument.Open(clean.Bytes);
                if (cleaned.Pages.Count != document.Pages.Count) failures.Add($"{files}: sanitized page count");
                bool layers = clean.Removed.Any(f => f.Item == SanitizeItem.HiddenLayers);
                if (layers) layerFiles++;
                else if (Text(cleaned) != text) failures.Add($"{files}: sanitized text");
                sanitized++;
                done++;
            }
            catch (PdfReadException)
            {
                skipped++;
            }
        }
        string savings = string.Join(", ", presets.Select(p => $"{p} {100.0 * (plainTotal - optimizedTotal[p]) / Math.Max(1, plainTotal):F1}%"));
        output.WriteLine($"{files} files, {done} optimised, {skipped} skipped, {sanitized} cleaned ({layerFiles} with hidden layers), {pigReads} read by PdfPig, {failures.Count} failures");
        output.WriteLine($"plain rewrites {plainTotal} bytes; saved against them: {savings}; cleaned total {sanitizedTotal} bytes");
        output.WriteLine($"Small with no codec saved {100.0 * (plainTotal - smallWithoutCodec) / Math.Max(1, plainTotal):F1}%");
        Assert.Empty(failures);
    }
}
