using System.Diagnostics;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

// Checks every file in the list LAZYPDF_CORPUS names (one path per line), tags the untagged ones,
// reopens them and compares text and tags; does nothing without it. Only counts are printed.
public class AccessibilityCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileIsCheckedAndEveryUntaggedFileCanBeTagged()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, unreadable = 0, tagged = 0, untagged = 0, withTree = 0, done = 0, partly = 0, none = 0, pagesTagged = 0, pagesSkipped = 0;
        int textChanged = 0, treeMismatch = 0, pigFailed = 0, reopenFailed = 0, figures = 0, elements = 0, passed = 0, failed = 0, person = 0;
        var problems = new List<string>();
        var watch = Stopwatch.StartNew();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            PdfDocument document;
            try
            {
                document = PdfDocument.Open(path);
            }
            catch (PdfReadException)
            {
                unreadable++;
                continue;
            }

            using (document)
            {
                files++;
                var report = AccessibilityChecker.Check(document);
                passed += report.Passed;
                failed += report.Failed;
                person += report.NeedsPerson;
                if (document.IsTagged)
                {
                    tagged++;
                    Assert.NotNull(ReadingOrder.Export(document));
                    continue;
                }

                untagged++;
                try
                {
                    string[] before = [.. document.Pages.Select(p => TextPage.Create(document, p).Text)];
                    var result = AutoTagger.Tag(document, new AutoTagOptions("en-US"));
                    if (result.AlreadyTagged)
                    {
                        withTree++;
                        continue;
                    }
                    pagesTagged += result.Pages;
                    pagesSkipped += result.SkippedPages;
                    figures += result.Figures;
                    if (result.Pages == 0) none++;
                    else if (result.SkippedPages > 0) partly++;
                    else done++;

                    var bytes = document.SaveRewrite();
                    using var again = PdfDocument.Open(bytes);
                    var tree = StructureTree.Read(again);
                    if (result.Pages > 0) elements += tree?.Elements.Count() ?? 0;
                    if (!Verify(again, tree, before, result.Pages > 0)) textChanged++;
                    if (result.Pages > 0 && !TreeMatchesContent(again, tree)) treeMismatch++;
                    if (result.Pages > 0)
                    {
                        try
                        {
                            using var pig = PigDocument.Open(bytes);
                            _ = pig.GetPage(1).Text;
                        }
                        catch (Exception e) when (e is not Xunit.Sdk.XunitException)
                        {
                            pigFailed++;
                        }
                    }
                }
                catch (Exception e) when (e is PdfReadException or InvalidOperationException)
                {
                    reopenFailed++;
                    if (problems.Count < 10) problems.Add(e.GetType().Name + ": " + e.Message);
                }
            }
        }

        output.WriteLine($"files {files}, unreadable {unreadable}, already tagged {tagged}, untagged {untagged} (with an unmarked tree {withTree})");
        output.WriteLine($"tagged whole {done}, in part {partly}, not at all {none}; pages tagged {pagesTagged}, skipped {pagesSkipped}, elements {elements}, figures {figures}");
        output.WriteLine($"checks passed {passed}, failed {failed}, needing a person {person}");
        output.WriteLine($"text changed {textChanged}, tree and content differ {treeMismatch}, PdfPig failed {pigFailed}, reopen or write failed {reopenFailed}, {watch.Elapsed.TotalSeconds:F0} s");
        foreach (string problem in problems) output.WriteLine(problem);

        Assert.Equal(0, textChanged);
        Assert.Equal(0, treeMismatch);
        Assert.Equal(0, pigFailed);
        Assert.Equal(0, reopenFailed);
    }

    private static bool Verify(PdfDocument document, StructureTree? tree, string[] before, bool tagged)
    {
        if (document.Pages.Count != before.Length) return false;
        for (int i = 0; i < before.Length; i++)
        {
            if (TextPage.Create(document, document.Pages[i]).Text != before[i]) return false;
        }
        return !tagged || (tree is not null && document.IsTagged);
    }

    // Every sequence the content of a tagged page opens is in the tree, and the parent tree names the element that holds it.
    private static bool TreeMatchesContent(PdfDocument document, StructureTree? tree)
    {
        if (tree is null) return false;
        foreach (var page in document.Pages)
        {
            var inTree = tree.Contents.Where(c => c.PageIndex == page.Index && c.Stream is null).ToList();
            if (inTree.Count == 0) continue;
            var inContent = AccessKit.Sequences(document, page.Index).Where(s => s.Mcid >= 0).Select(s => s.Mcid).ToList();
            if (!inContent.Order().SequenceEqual(inTree.Select(c => c.Mcid).Order())) return false;
            if (document.Integer(page.Dictionary, "StructParents") is not { } key) return false;
            foreach (var content in inTree)
            {
                var owner = tree.ElementFor(key, content.Mcid);
                if (owner is null || !owner.Kids.Contains(content)) return false;
            }
        }
        return true;
    }
}
