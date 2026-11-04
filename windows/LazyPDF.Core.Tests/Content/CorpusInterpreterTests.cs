using System.Diagnostics;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Runs every page of every file in the list LAZYPDF_CORPUS names (one path per line) through the
// interpreter; does nothing without it. Only counts and times are printed.
public class CorpusInterpreterTests(ITestOutputHelper output)
{
    private sealed class Counter : ContentVisitor
    {
        public long Glyphs, Paths, Images, Forms, Unicode;

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            Glyphs++;
            if (glyph.Unicode is not null) Unicode++;
        }

        public override void PaintPath(ContentContext context, PathInfo path) => Paths++;

        public override void PaintImage(ContentContext context, ImageInfo image) => Images++;

        public override void BeginForm(ContentContext context, FormInfo form) => Forms++;
    }

    [Fact]
    public void EveryPageRunsWithoutAnythingButPdfReadException()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, pages = 0, truncated = 0;
        var counter = new Counter();
        var other = new List<string>();
        double slowest = 0;
        var total = Stopwatch.StartNew();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            try
            {
                using var document = PdfDocument.Open(path);
                files++;
                var interpreter = new ContentInterpreter(document);
                var watch = Stopwatch.StartNew();
                foreach (var page in document.Pages)
                {
                    try
                    {
                        interpreter.Run(page, counter);
                        pages++;
                        if (interpreter.IsTruncated) truncated++;
                    }
                    catch (PdfReadException)
                    {
                    }
                }
                slowest = Math.Max(slowest, watch.Elapsed.TotalSeconds);
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                other.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"{files} files, {pages} pages, {counter.Glyphs} glyphs ({counter.Unicode} with text), {counter.Paths} paths, {counter.Images} images, {counter.Forms} forms, {truncated} truncated; slowest file {slowest:0.0} s, total {total.Elapsed.TotalSeconds:0.0} s");
        Assert.True(other.Count == 0, string.Join("\n", other));
        Assert.True(slowest < 120, $"slowest file took {slowest:0.0} s");
    }
}
