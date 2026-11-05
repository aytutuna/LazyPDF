using System.Diagnostics;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.App.Tests;

// Reads the scanned pages of the files in the list LAZYPDF_CORPUS names (one path per line) for blanks. Does
// nothing without it; only counts are printed.
public sealed class ScanFormCorpusTests(ITestOutputHelper output)
{
    private const int MaxPages = 20;

    [Fact]
    public void ScannedPagesAreReadWithoutFailing()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, scans = 0, withBlanks = 0, proposals = 0, pixels = 0, mostOnAPage = 0, unreadable = 0;
        var times = new List<long>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0 && File.Exists(l)))
        {
            PdfEditSession session;
            try
            {
                session = PdfEditSession.Open(path);
            }
            catch (PdfReadException)
            {
                unreadable++;
                continue;
            }
            files++;
            using var renderer = new WindowsPageRenderer();
            if (!renderer.Load(session, null)) continue;
            var document = session.Document;
            foreach (var kind in OcrTriage.ClassifyAll(document).Take(MaxPages).Select((k, i) => (Kind: k, Index: i)))
            {
                if (kind.Kind is not (OcrPageKind.Picture or OcrPageKind.OwnLayer or OcrPageKind.ForeignLayer)) continue;
                scans++;
                var clock = Stopwatch.StartNew();
                var found = FieldDetector.Detect(document, kind.Index, renderer);
                times.Add(clock.ElapsedMilliseconds);
                proposals += found.Count;
                pixels += found.Count(p => p.FromPixels);
                mostOnAPage = Math.Max(mostOnAPage, found.Count);
                if (found.Count > 0) withBlanks++;
            }
        }
        times.Sort();
        output.WriteLine($"{files} files, {unreadable} not opened, {scans} scanned pages, {withBlanks} with proposals, {proposals} proposals ({pixels} from pixels), most on one page {mostOnAPage}");
        if (times.Count > 0) output.WriteLine($"milliseconds per page: median {times[times.Count / 2]}, slowest {times[^1]}");
    }
}
