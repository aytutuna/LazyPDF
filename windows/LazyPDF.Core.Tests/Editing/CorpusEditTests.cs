using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// On every page with text of a personal corpus (LAZYPDF_CORPUS names the list file): replace the first word of a
// line with another of the same length, commit, reopen, and check the new word is there and the other lines read as before.
// LAZYPDF_EDIT_OUT names a folder that gets the first few edited files, to be drawn and looked at.
public class CorpusEditTests(ITestOutputHelper output)
{
    private static string[] Files()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        return string.IsNullOrEmpty(list) || !File.Exists(list) ? [] : [.. File.ReadAllLines(list).Where(l => l.Trim().Length > 0)];
    }

    // The letters of the word in another order, so that every glyph is one the font has.
    private static string Shuffled(string word)
    {
        string rotated = word[1..] + word[0];
        return rotated != word ? rotated : new string(word.Reverse().ToArray());
    }

    private static List<string> Lines(PdfDocument document, int page) =>
        [.. TextPage.Create(document, document.Pages[page]).Lines.Select(l => l.Text)];

    [Fact]
    public void FirstWordOfALineIsReplacedByOneOfTheSameLength()
    {
        var files = Files();
        if (files.Length == 0) return;
        var failures = new SortedDictionary<string, int>();
        int pages = 0, ok = 0, opened = 0, unopened = 0, saved = 0;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        foreach (string path in files)
        {
            PdfEditSession session;
            try
            {
                session = PdfEditSession.Open(path);
            }
            catch (PdfReadException)
            {
                unopened++;
                continue;
            }
            opened++;
            for (int p = 0; p < session.Document.Pages.Count; p++)
            {
                string outcome = Attempt(session, p, out bool attempted);
                if (!attempted) continue;
                pages++;
                if (outcome == "ok")
                {
                    ok++;
                    if (saved < 4 && p > 0 && Environment.GetEnvironmentVariable("LAZYPDF_EDIT_OUT") is { } folder)
                    {
                        Directory.CreateDirectory(folder);
                        File.WriteAllBytes(Path.Combine(folder, $"corpus-{saved++}-page{p}.pdf"), session.Current.ToArray());
                    }
                }
                else failures[outcome] = failures.GetValueOrDefault(outcome) + 1;
                while (session.CanUndo) session.Undo();
            }
        }
        output.WriteLine($"files {files.Length}, opened {opened}, not opened {unopened}, pages tried {pages}, replaced {ok}, rate {(pages == 0 ? 0 : 100.0 * ok / pages):0.0}%, {clock.Elapsed.TotalSeconds:0} s");
        foreach (var (reason, n) in failures) output.WriteLine($"  {n,5}  {reason}");
        Assert.DoesNotContain(failures.Keys, k => k.StartsWith("exception"));
        Assert.True(pages == 0 || ok >= pages / 2);
    }

    private static string Attempt(PdfEditSession session, int page, out bool attempted)
    {
        attempted = false;
        try
        {
            var editor = new PageEditor(session, page, new EditArialSource());
            var text = editor.Text;
            var word = text.Words.FirstOrDefault(w => w.Text.Length >= 3 && w.Text.All(char.IsLetter) && text.Lines[w.Line].Range.Start == w.Range.Start);
            if (word is null) return "no word";
            attempted = true;
            var before = Lines(session.Document, page);
            string replacement = Shuffled(word.Text);
            var result = editor.ReplaceText(word.Range, replacement);
            if (!result.Done) return "refused: " + result.Problem;
            var document = PdfDocument.Open(session.Current.ToArray());
            var after = Lines(document, page);
            if (TextSearch.Find(TextPage.Create(document, document.Pages[page]), replacement, new TextSearchOptions(MatchCase: true)).Count == 0)
                return "new word not found" + Detail(text.Chars[word.Range.Start], result, before[word.Line], after);
            before.RemoveAt(word.Line);
            return before.All(after.Remove) ? "ok" : "another line changed";
        }
        catch (Exception e) when (e is not Xunit.Sdk.XunitException)
        {
            return "exception " + e.GetType().Name;
        }
    }

    // What kind of text it was, to sort the failures by.
    private static string Detail(TextChar first, TextEditResult result, string line, List<string> after)
    {
        string kind = first.Font is null ? "no font" : first.Font.IsComposite ? "composite" : first.Font.IsType3 ? "type3" : "simple";
        string substituted = result.Substitutions.Count > 0 ? ", substituted" : "";
        string form = first.Form is null ? "" : ", in form";
        string moved = after.Contains(line) ? ", line unchanged" : "";
        return $" [{kind}{substituted}{form}{moved}]";
    }
}
