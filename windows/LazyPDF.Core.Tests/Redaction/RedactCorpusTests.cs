using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

// Redacts one word on each of the first pages of every file in the list LAZYPDF_CORPUS names (one path
// per line) and checks the word is gone, the other words are the same and the output reopens. Does
// nothing without the variable; only counts are printed.
public class RedactCorpusTests(ITestOutputHelper output)
{
    private const int MaxPages = 25;

    [Fact]
    public void OneWordPerPageIsGoneAndTheRestStays()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, skipped = 0, pages = 0, gone = 0, same = 0, reopened = 0, readByPig = 0, nonEmptyPages = 0, flattened = 0, kept = 0;
        var failures = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            try
            {
                using var document = PdfDocument.Open(path);
                if (document.Pages.Count == 0) continue;
                var marks = new List<RedactionMark>();
                var before = new Dictionary<int, (List<string> Words, string Target)>();
                for (int p = 0; p < Math.Min(MaxPages, document.Pages.Count); p++)
                {
                    var text = TextPage.Create(document, document.Pages[p]);
                    var words = text.Words.Where(w => w.Text.Length >= 4 && w.Text.Any(char.IsLetterOrDigit)).ToList();
                    if (words.Count == 0) continue;
                    var word = words[words.Count / 2];
                    marks.Add(new RedactionMark(p, text.Quads(word.Range)));
                    before[p] = ([.. text.Words.Select(w => w.Text)], word.Text);
                }
                if (marks.Count == 0) continue;

                var result = new PdfRedactor(document).Apply(marks, RedactionKit.Drawing(document));
                flattened += result.Report.Flattened.Count;
                using var again = PdfDocument.Open(result.Bytes);
                reopened++;
                try
                {
                    using var pig = PigDocument.Open(result.Bytes);
                    pig.GetPage(1);
                    readByPig++;
                }
                catch (Exception)
                {
                }

                foreach (var mark in marks)
                {
                    pages++;
                    nonEmptyPages++;
                    var after = TextPage.Create(again, again.Pages[mark.Page]);
                    var areas = mark.Quads.Select(MarkArea.Of).ToList();
                    bool inside = after.Chars.Any(c => !c.IsSpace && areas.Any(a => Geometry.GlyphMeets(Geometry.Corners(c.Quad), a)));
                    if (inside) failures.Add($"file {files} page {mark.Page + 1}: text left under the mark");
                    else gone++;

                    if (result.Report.Flattened.Contains(mark.Page)) continue;
                    kept++;
                    var (words, target) = before[mark.Page];
                    var expected = new List<string>(words);
                    expected.Remove(target);
                    var left = after.Words.Select(w => w.Text).ToList();
                    if (expected.Order(StringComparer.Ordinal).SequenceEqual(left.Order(StringComparer.Ordinal))) same++;
                }
            }
            catch (PdfReadException)
            {
                skipped++;
            }
            catch (Exception e)
            {
                failures.Add($"file {files}: {e.GetType().Name} {e.Message}");
            }
        }
        output.WriteLine($"{files} files, {skipped} skipped, {reopened} redacted and reopened ({readByPig} read by PdfPig), {pages} pages: word gone on {gone}, other words the same on {same} of {kept} pages not flattened, {flattened} pages flattened, {failures.Count} failures");
        foreach (string f in failures.Take(20)) output.WriteLine(f);
        Assert.Empty(failures);
        Assert.True(same >= kept * 0.9, $"other words the same on {same} of {kept} pages");
    }
}
