using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Runs a fake recognizer over every page of the files in the list LAZYPDF_CORPUS names (one path per
// line) that triage takes for a picture or a drawing. Does nothing without it; only counts are printed.
public class CorpusOcrTests(ITestOutputHelper output)
{
    // Two words in the top left corner whatever the size of the picture.
    private sealed class CornerRecognizer : ITextRecognizer
    {
        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
        {
            double w = image.Width, h = image.Height;
            IReadOnlyList<OcrWord> words = [OcrKit.Word("page", w * 0.1, h * 0.1, w * 0.3, h * 0.04), OcrKit.Word("tail", w * 0.45, h * 0.1, w * 0.3, h * 0.04)];
            return Task.FromResult(words);
        }
    }

    private const int MaxPages = 40;

    [Fact]
    public async Task PagesThatNeedOcrTakeTheLayerAndKeepTheFileReadable()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, withWork = 0, pages = 0, pictures = 0, layers = 0, ownLayers = 0, locked = 0, readByPig = 0;
        var kinds = new Dictionary<OcrPageKind, int>();
        var failures = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            PdfEditSession session;
            try
            {
                session = PdfEditSession.Open(path);
            }
            catch (PdfReadException)
            {
                locked++;
                continue;
            }
            try
            {
                var document = session.Document;
                var inspected = Enumerable.Range(0, Math.Min(document.Pages.Count, MaxPages)).ToList();
                foreach (var kind in OcrTriage.ClassifyAll(document).Take(MaxPages)) kinds[kind] = kinds.GetValueOrDefault(kind) + 1;
                var wanted = inspected.Where(i => OcrTriage.NeedsOcr(OcrTriage.Classify(document, document.Pages[i]), false, false)).ToList();
                pictures += wanted.Count(i => OcrTriage.Classify(document, document.Pages[i]) == OcrPageKind.Picture);
                if (wanted.Count == 0) continue;

                withWork++;
                var recognizer = new CornerRecognizer();
                var result = await PdfSearchable.RunAsync(session, recognizer, new FakeRenderer(document), new OcrOptions(Dpi: 72, Pages: inspected));
                pages += result.Added;
                if (result.Added != wanted.Count || result.Words != 2 * wanted.Count) failures.Add($"{files}: {result.Added} of {wanted.Count}");

                using var reopened = PdfDocument.Open(session.Current.ToArray());
                int has = wanted.Count(i => PdfOcrLayer.Has(reopened, reopened.Pages[i]));
                layers += has;
                if (has != wanted.Count) failures.Add($"{files}: layer on {has} of {wanted.Count} after reopen");
                foreach (int i in wanted.Take(3))
                {
                    var words = TextPage.Create(reopened, reopened.Pages[i]).Words.Select(w => w.Text);
                    if (!words.Contains("tail")) failures.Add($"{files}: page {i} text");
                }

                var again = await PdfSearchable.RunAsync(session, recognizer, new FakeRenderer(session.Document), new OcrOptions(Dpi: 72, Existing: OcrExisting.Replace, Pages: inspected));
                if (again.Added != wanted.Count) failures.Add($"{files}: replace {again.Added} of {wanted.Count}");
                using var twice = PdfDocument.Open(session.Current.ToArray());
                ownLayers += wanted.Count(i => OcrKit.LayerStreams(twice, i) == 1);
                if (wanted.Any(i => OcrKit.LayerStreams(twice, i) != 1)) failures.Add($"{files}: layers after replace");

                try
                {
                    using var pig = UglyToad.PdfPig.PdfDocument.Open(twice.SaveRewrite());
                    pig.GetPage(wanted[0] + 1);
                    readByPig++;
                }
                catch (Exception)
                {
                }
            }
            catch (PdfReadException)
            {
                locked++;
            }
        }
        output.WriteLine($"{files} files, {locked} unreadable or locked, {withWork} with pages for OCR ({pages} pages, {pictures} pictures), "
                         + $"{layers} layers after reopen, {ownLayers} single layers after replace, {readByPig} read by PdfPig, {failures.Count} failures");
        output.WriteLine(string.Join(", ", kinds.OrderBy(k => k.Key).Select(k => $"{k.Key} {k.Value}")));
        Assert.Empty(failures);
    }
}
