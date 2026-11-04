using System.Diagnostics;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Compares every file in the list LAZYPDF_CORPUS names (one path per line) with itself, and with a
// copy in which one word of the page content was changed. Does nothing without it; only counts and
// times are printed.
public class CorpusCompareTests(ITestOutputHelper output)
{
    private sealed record Edit(int Page, string Word, string Reversed, int Operation, int Element, int Offset);

    [Fact]
    public void EveryFileEqualsItselfAndOneEditedWordIsFound()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, opened = 0, pages = 0, identical = 0, edited = 0, exact = 0;
        var failures = new List<string>();
        var selfTime = new Stopwatch();
        var editTime = new Stopwatch();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            byte[] bytes = File.ReadAllBytes(path);
            try
            {
                using var a = PdfDocument.Open(bytes);
                using var b = PdfDocument.Open(bytes);
                opened++;
                pages += a.Pages.Count;

                selfTime.Start();
                var self = PdfComparer.Compare(a, b);
                selfTime.Stop();
                if (self.IsIdentical) identical++;
                else failures.Add($"{files}: self compare gave {self.Changes.Count} changes ({self.Summary.Text} text, {self.Summary.Format} format, {self.Summary.Images} images, {self.Summary.Annotations} notes, {self.Summary.Pages} pages, {self.Summary.Document} document)");

                var edit = FindEdit(a);
                if (edit is null) continue;
                edited++;
                using var changed = PdfDocument.Open(bytes);
                Apply(changed, edit);
                using var reopened = PdfDocument.Open(changed.SaveRewrite());
                editTime.Start();
                var result = PdfComparer.Compare(a, reopened);
                editTime.Stop();
                var change = result.Changes.Count == 1 ? result.Changes[0] : null;
                if (change is { Kind: ChangeKind.Changed, Area: ChangeArea.Text } && change.OldText == edit.Word && change.NewText == edit.Reversed && change.NewPage == edit.Page) exact++;
                else failures.Add($"{files}: edit on page {edit.Page} gave {result.Changes.Count} changes ({string.Join(",", result.Changes.Take(4).Select(c => c.Kind + "/" + c.Area))})");
            }
            catch (PdfReadException)
            {
                // Files that need a password or that cannot be read are not part of this test.
            }
        }
        output.WriteLine($"files {files}, opened {opened}, pages {pages}");
        output.WriteLine($"self compare: {identical} identical of {opened}, {selfTime.Elapsed.TotalSeconds:0.0} s");
        output.WriteLine($"one word edited: {edited} files, {exact} found exactly, {editTime.Elapsed.TotalSeconds:0.0} s");
        foreach (string failure in failures.Take(30)) output.WriteLine(failure);
        Assert.Empty(failures);
    }

    /// <summary>The first word of letters only whose glyphs all come from one byte string of a simple font, so that reversing its bytes gives another word that the font can draw.</summary>
    private static Edit? FindEdit(PdfDocument document)
    {
        var cache = new TextCache(document);
        for (int p = 0; p < document.Pages.Count; p++)
        {
            var text = cache.Get(p);
            foreach (var word in text.Words)
            {
                if (word.Text.Length < 3 || !word.Text.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z') || word.Text.Distinct().Count() < 2) continue;
                string reversed = new(word.Text.Reverse().ToArray());
                if (reversed == word.Text || word.Range.Count != word.Text.Length) continue;
                var chars = Enumerable.Range(word.Range.Start, word.Range.Count).Select(i => text.Chars[i]).ToList();
                var first = chars[0];
                bool sameString = chars.All(c => c.Form is null && c.Font is { IsComposite: false, IsType3: false } && c.OperatorIndex == first.OperatorIndex
                    && c.Element == first.Element && !c.IsImplied && c.Text.Length == 1);
                bool consecutive = chars.Select((c, i) => c.Offset == first.Offset + i).All(x => x);
                if (sameString && consecutive) return new Edit(p, word.Text, reversed, first.OperatorIndex, first.Element, first.Offset);
            }
        }
        return null;
    }

    private static void Apply(PdfDocument document, Edit edit)
    {
        var page = document.Pages[edit.Page];
        var operations = ContentParser.Parse(page.Contents()).ToList();
        var operand = operations[edit.Operation].Operands[0];
        var target = operand is PdfArray array ? (PdfString)array.Items[edit.Element] : (PdfString)operand;
        byte[] original = (byte[])target.Bytes.Clone();
        for (int i = 0; i < edit.Word.Length; i++) target.Bytes[edit.Offset + i] = original[edit.Offset + edit.Word.Length - 1 - i];
        page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), ContentWriter.Write(operations)));
    }
}
