using System.Diagnostics;
using System.IO.Compression;
using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Runs every writer on every file in the list LAZYPDF_CORPUS names (one path per line) and parses
// the XML parts back. Does nothing without it; only counts and times are printed.
public class CorpusExportTests(ITestOutputHelper output)
{
    private const int MaxPages = 300;

    [Fact]
    public void EveryFormatOnEveryFileThrowsNothingButPdfReadException()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, exported = 0, unreadable = 0, truncated = 0, pages = 0, tables = 0, headings = 0, listItems = 0, pictures = 0, extracted = 0;
        var failures = new List<string>();
        var watch = Stopwatch.StartNew();
        long analyseMs = 0, writeMs = 0;
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            try
            {
                using var document = PdfDocument.Open(path);
                var chosen = Enumerable.Range(0, Math.Min(document.Pages.Count, MaxPages)).ToList();
                if (document.Pages.Count > MaxPages) truncated++;

                var step = Stopwatch.StartNew();
                var model = ExportLayout.Analyze(document, chosen);
                analyseMs += step.ElapsedMilliseconds;
                step.Restart();

                pages += model.Pages.Count;
                var blocks = model.Pages.SelectMany(p => p.Blocks).ToList();
                tables += blocks.OfType<ExportTable>().Count();
                headings += blocks.OfType<ExportParagraph>().Count(p => p.Heading > 0);
                listItems += blocks.OfType<ExportParagraph>().Count(p => p.Item is not null);
                pictures += model.Pages.Sum(p => p.Pictures.Count);

                var docx = DocxWriter.Make(model);
                var xlsx = XlsxWriter.Make(model);
                var pptx = PptxWriter.Make(model);
                foreach (var package in new[] { docx, xlsx, pptx }) ParseXml(package);
                _ = HtmlWriter.Reflowed(model);
                _ = HtmlWriter.Fixed(model);
                _ = RtfWriter.Make(model);
                _ = MarkdownWriter.Make(model);
                _ = PlainTextWriter.Make(model);
                writeMs += step.ElapsedMilliseconds;
                extracted += ImageExtractor.Extract(document, chosen).Count;
                exported++;
            }
            catch (PdfReadException)
            {
                unreadable++;
            }
            catch (Exception e)
            {
                failures.Add($"{files}: {e.GetType().Name} {e.Message} {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"files {files}, exported {exported}, unreadable {unreadable}, over {MaxPages} pages {truncated}; pages {pages}, tables {tables}, headings {headings}, list items {listItems}, pictures {pictures}, extracted {extracted}");
        output.WriteLine($"analyse {analyseMs} ms, write {writeMs} ms, total {watch.ElapsedMilliseconds} ms");
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    private static void ParseXml(byte[] package)
    {
        using var zip = new ZipArchive(new MemoryStream(package), ZipArchiveMode.Read);
        foreach (var entry in zip.Entries.Where(e => e.FullName.EndsWith(".xml") || e.FullName.EndsWith(".rels")))
        {
            using var stream = entry.Open();
            XDocument.Load(stream);
        }
    }
}
