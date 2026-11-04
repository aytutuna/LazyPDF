using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// The other changes on the first pages of every corpus file (LAZYPDF_CORPUS): none may throw and the file must reopen
// without repairs. A paragraph set again with its own text is counted by whether its words read back the same.
public class CorpusSweepTests(ITestOutputHelper output)
{
    // Ten changes a page cost about a second a page, so a file gets its first few pages.
    private static int PagesPerFile => int.TryParse(Environment.GetEnvironmentVariable("LAZYPDF_CORPUS_PAGES"), out int n) ? n : 3;

    private static string[] Files()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        return string.IsNullOrEmpty(list) || !File.Exists(list) ? [] : [.. File.ReadAllLines(list).Where(l => l.Trim().Length > 0)];
    }

    private static List<string> Words(PdfDocument document, int page) =>
        [.. TextPage.Create(document, document.Pages[page]).Words.Select(w => w.Text).Order()];

    [Fact]
    public void EveryKindOfChangeLeavesAFileThatReopens()
    {
        var files = Files();
        if (files.Length == 0) return;
        var outcomes = new SortedDictionary<string, int>();
        void Count(string what, string outcome) => outcomes[$"{what}: {outcome}"] = outcomes.GetValueOrDefault($"{what}: {outcome}") + 1;
        foreach (string path in files)
        {
            PdfEditSession session;
            try
            {
                session = PdfEditSession.Open(path);
            }
            catch (PdfReadException)
            {
                continue;
            }
            for (int p = 0; p < Math.Min(session.Document.Pages.Count, PagesPerFile); p++)
            {
                Run("set again", p, session, Count, editor =>
                {
                    var block = editor.Objects.OfType<TextObject>().FirstOrDefault(b => b.Lines.Count > 1 && !b.IsTable);
                    if (block is null) return null;
                    var before = Words(session.Document, p);
                    var result = editor.ReplaceParagraph(block, block.Text.ReplaceLineEndings(" "));
                    if (!result.Done) return "refused: " + result.Problem;
                    var after = Words(PdfDocument.Open(session.Current.ToArray()), p);
                    if (before.SequenceEqual(after)) return "ok";
                    if (result.Substitutions.Count > 0) return "ok, other font used";
                    int lost = before.Except(after).Count(), gained = after.Except(before).Count();
                    return $"words changed (lost {Math.Min(lost, 3)}, gained {Math.Min(gained, 3)})";
                });
                Run("bigger", p, session, Count, editor =>
                    editor.Text.Lines.Count == 0 ? null : Done(editor.SetTextStyle([editor.Text.Lines[0].Range], new TextStyleChange(Size: 14, Color: new RgbColor(200, 0, 0)))));
                Run("align", p, session, Count, editor =>
                    editor.Objects.OfType<TextObject>().FirstOrDefault(b => b.Lines.Count > 1) is { } block ? Done(editor.SetAlignment(block, TextAlignment.Right)) : null);
                Run("spacing", p, session, Count, editor =>
                    editor.Objects.OfType<TextObject>().FirstOrDefault(b => b.Lines.Count > 1 && b.LineSpacing > 0) is { } block ? Done(editor.SetLineSpacing(block, block.LineSpacing * 1.5)) : null);
                Run("delete word", p, session, Count, editor =>
                    editor.Text.Words.Count == 0 ? null : Done(editor.DeleteText(editor.Text.Words[0].Range)));
                Run("text box", p, session, Count, editor =>
                    Done(editor.AddTextBox(new PdfRect(50, 50, 250, 120), "Added text, wrapped in its box.")));
                Run("delete objects", p, session, Count, editor =>
                    editor.Objects.Count == 0 ? null : Done(editor.Delete(editor.Objects.Take(3))));
                Run("rotate", p, session, Count, editor =>
                    editor.Objects.Count == 0 ? null : Done(editor.Rotate(editor.Objects.Take(3), 25)));
                Run("opacity", p, session, Count, editor =>
                    editor.Objects.OfType<PathObject>().Take(2).ToList() is { Count: > 0 } paths ? Done(editor.SetOpacity(paths, 0.5)) : null);
                Run("order", p, session, Count, editor =>
                    editor.Objects.FirstOrDefault(o => o is ImageObject or PathObject) is { } o ? Done(editor.Order(o, OrderMove.Front)) : null);
            }
        }
        foreach (var (what, n) in outcomes) output.WriteLine($"  {n,5}  {what}");
        Assert.DoesNotContain(outcomes.Keys, k => k.Contains("exception") || k.Contains("does not reopen"));
    }

    private static string Done(TextEditResult result) => result.Done ? "ok" : "refused: " + result.Problem;

    private static string Done(ObjectEditResult result) =>
        result.Done ? (result.Skipped.Count > 0 ? "ok, some skipped" : "ok") : "refused: " + string.Join("; ", result.Skipped.Select(s => s.Reason).Distinct());

    // One change on one page; the outcome is counted, the page checked and the change undone.
    private static void Run(string what, int page, PdfEditSession session, Action<string, string> count, Func<PageEditor, string?> change)
    {
        string? outcome;
        int repairs = session.Document.Repairs.Count;
        try
        {
            outcome = change(new PageEditor(session, page, new EditArialSource()));
            if (outcome is not null && outcome.StartsWith("ok"))
            {
                var document = PdfDocument.Open(session.Current.ToArray());
                TextPage.Create(document, document.Pages[page]);
                if (document.Repairs.Count > repairs) outcome = "does not reopen cleanly";
            }
        }
        catch (Exception e) when (e is not Xunit.Sdk.XunitException)
        {
            outcome = "exception " + e.GetType().Name;
        }
        if (outcome is not null) count(what, outcome);
        while (session.CanUndo) session.Undo();
    }
}
