using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// On every page of the corpus (LAZYPDF_CORPUS): move every object by the same amount, commit, reopen, and check that
// every glyph, picture and path the interpreter finds is where it was plus that amount.
public class CorpusMoveTests(ITestOutputHelper output)
{
    private const double Dx = 7, Dy = -4;

    private static string[] Files()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        return string.IsNullOrEmpty(list) || !File.Exists(list) ? [] : [.. File.ReadAllLines(list).Where(l => l.Trim().Length > 0)];
    }

    private sealed class Positions : ContentVisitor
    {
        public List<(string Kind, double X, double Y)> Seen { get; } = [];

        // A glyph with no ink has no block of its own.
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            if (!string.IsNullOrWhiteSpace(glyph.Unicode)) Seen.Add(("g", glyph.Matrix.E, glyph.Matrix.F));
        }

        public override void PaintImage(ContentContext context, ImageInfo image) => Seen.Add(("i", image.Matrix.E, image.Matrix.F));

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke) Seen.Add(("p", path.Bounds.Left, path.Bounds.Bottom));
        }
    }

    private static List<(string Kind, double X, double Y)> Read(PdfDocument document, int page)
    {
        var positions = new Positions();
        new ContentInterpreter(document) { WalkPatterns = false }.Run(document.Pages[page], positions);
        return positions.Seen;
    }

    [Fact]
    public void EveryObjectOfEveryPageMovesByTheSameAmount()
    {
        var files = Files();
        if (files.Length == 0) return;
        var outcomes = new SortedDictionary<string, int>();
        int pages = 0;
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
            for (int p = 0; p < session.Document.Pages.Count; p++)
            {
                string outcome;
                try
                {
                    outcome = Attempt(session, p);
                }
                catch (Exception e) when (e is not Xunit.Sdk.XunitException)
                {
                    outcome = "exception " + e.GetType().Name + " at " + (e.StackTrace ?? "").ReplaceLineEndings("|").Split('|').Take(3).Aggregate((a, b) => a + " <- " + b.Trim());
                }
                pages++;
                outcomes[outcome] = outcomes.GetValueOrDefault(outcome) + 1;
                while (session.CanUndo) session.Undo();
            }
        }
        output.WriteLine($"pages {pages}");
        foreach (var (what, n) in outcomes) output.WriteLine($"  {n,5}  {what}");
        Assert.DoesNotContain(outcomes.Keys, k => k.StartsWith("exception"));
    }

    private static string Attempt(PdfEditSession session, int page)
    {
        var editor = new PageEditor(session, page);
        if (editor.Objects.Count == 0) return "no objects";
        var before = Read(session.Document, page);
        var result = editor.Move(editor.Objects, Dx, Dy);
        if (!result.Done) return "refused: " + string.Join("; ", result.Skipped.Select(s => s.Reason).Distinct());
        var after = Read(PdfDocument.Open(session.Current.ToArray()), page);
        string skipped = result.Skipped.Count > 0 ? " with " + string.Join("; ", result.Skipped.Select(s => s.Reason).Distinct()) : "";
        if (after.Count != before.Count) return "different count" + skipped;
        int off = 0;
        for (int i = 0; i < before.Count; i++)
        {
            if (before[i].Kind != after[i].Kind) return "different content" + skipped;
            if (Math.Abs(after[i].X - before[i].X - Dx) > 0.01 || Math.Abs(after[i].Y - before[i].Y - Dy) > 0.01) off++;
        }
        if (result.Skipped.Count > 0) return "moved, some skipped: " + string.Join("; ", result.Skipped.Select(s => s.Reason).Distinct());
        if (off == 0) return "ok";
        string kinds = string.Concat(Enumerable.Range(0, before.Count).Where(i => Math.Abs(after[i].X - before[i].X - Dx) > 0.01 || Math.Abs(after[i].Y - before[i].Y - Dy) > 0.01).Select(i => before[i].Kind[0]).Distinct().Order());
        return $"some not moved [{kinds}]{(editor.Objects.Any(o => o.Forms.Count > 0) ? " forms" : "")}";
    }
}
