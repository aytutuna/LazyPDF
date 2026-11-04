using System.Diagnostics;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;
using Pig = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

// When LAZYPDF_CORPUS names a text file of paths, every openable file gets a highlight, a free text
// and a stamp, its first text field filled and page 1 deleted (when there are several), each step
// committed through an edit session and read back. LAZYPDF_CORPUS_OUT, when set, names a folder that
// receives the results as n.pdf for other readers. Only counts are printed.
public class IntegrationCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EditsCommitAndReopenForEveryFile()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;
        string? outDir = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS_OUT");
        if (!string.IsNullOrEmpty(outDir)) Directory.CreateDirectory(outDir);

        int stamped_ = 0, merged_ = 0;
        byte[]? previous = null;
        int files = 0, refused = 0, committed = 0, filled = 0, deleted = 0, annotated = 0, pigFailed = 0, pigFailedBefore = 0;
        var problems = new List<string>();
        var date = new DateTimeOffset(2026, 6, 1, 12, 0, 0, TimeSpan.Zero);
        var timer = Stopwatch.StartNew();
        int number = 0;
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            number++;
            if (!File.Exists(path)) continue;
            PdfEditSession session;
            byte[] original;
            try
            {
                original = File.ReadAllBytes(path);
                session = PdfEditSession.Open(original);
                if (session.Document.Pages.Count == 0) throw new PdfReadException(PdfReadProblem.Damaged, "no pages");
            }
            catch (PdfReadException)
            {
                refused++;
                continue;
            }

            files++;
            var document = session.Document;
            int pages = document.Pages.Count, repairs = document.Repairs.Count;
            try
            {
                int target = pages > 1 ? 1 : 0;
                var box = document.Pages[target].CropBox;
                if (box.IsEmpty) continue;
                var writer = new PdfAnnotationWriter(document);
                var info = new AnnotationInfo("corpus", "c", Date: date);
                double w = box.Width, h = box.Height;
                writer.AddTextMarkup(document.Pages[target], AnnotationType.Highlight,
                    [MarkupQuad.FromRect(new PdfRect(box.Left + w * 0.1, box.Bottom + h * 0.5, box.Left + w * 0.6, box.Bottom + h * 0.55))], info);
                writer.AddFreeText(document.Pages[target], new PdfRect(box.Left + w * 0.1, box.Bottom + h * 0.2, box.Left + w * 0.6, box.Bottom + h * 0.3), "Free text", info: info);
                writer.AddStamp(document.Pages[target], new PdfRect(box.Left + w * 0.1, box.Bottom + h * 0.7, box.Left + w * 0.4, box.Bottom + h * 0.8), "Approved", info);
                Commit(session, "annotate", problems, path, number);
                annotated++;
                committed++;
                document = session.Document;

                var form = PdfForm.Read(document);
                var field = form.Fields.FirstOrDefault(f => f.Kind == FieldKind.Text && !f.Has(FieldFlags.ReadOnly) && f.Widgets.Count > 0 && f.Widgets[0].PageIndex >= 0);
                if (field is not null && form.Xfa != XfaKind.Dynamic)
                {
                    form.SetValue(field.Name, "Filled");
                    Commit(session, "fill", problems, path, number);
                    filled++;
                    committed++;
                    document = session.Document;
                }

                if (pages > 1)
                {
                    PageOperations.Delete(document, [0]);
                    Commit(session, "delete", problems, path, number);
                    deleted++;
                    committed++;
                    document = session.Document;
                }

                var final = session.Current.ToArray();
                var again = PdfDocument.Open(final);
                if (again.Pages.Count != (pages > 1 ? pages - 1 : pages)) problems.Add($"{number}: page count {again.Pages.Count}");
                if (again.Repairs.Count > repairs) problems.Add($"{number}: repairs {repairs} -> {again.Repairs.Count}");
                var onPage = PdfAnnotations.Read(again, again.Pages[pages > 1 ? 0 : 0]);
                foreach (var type in new[] { AnnotationType.Highlight, AnnotationType.FreeText, AnnotationType.Stamp })
                    if (!onPage.Any(a => a.Type == type)) problems.Add($"{number}: lost {type}");

                bool openedBefore = PigOpens(original);
                if (openedBefore && !PigOpens(final, again.Pages.Count)) pigFailed++;
                if (!openedBefore) pigFailedBefore++;
                if (!string.IsNullOrEmpty(outDir)) File.WriteAllBytes(Path.Combine(outDir, $"{number}.pdf"), final);

                var stamped = PdfDocument.Open(final);
                var stamper = new PdfStamper(stamped);
                stamper.AddWatermark(new WatermarkSpec { Text = "COPY" });
                stamper.AddHeaderFooter(new HeaderFooterSpec { Header = new HeaderFooterBand(Center: "{file}"), Footer = new HeaderFooterBand(Right: "{page}/{pages}"), FileName = "x.pdf" });
                PageOperations.Rotate(stamped, [0], 90);
                var packed = stamped.SaveRewrite(new PdfSaveOptions(UseObjectStreams: true));
                var packedBack = PdfDocument.Open(packed);
                if (packedBack.Repairs.Count > again.Repairs.Count) problems.Add($"{number}: stamped repairs");
                if (packedBack.Pages.Count != again.Pages.Count || !PigOpens(packed, again.Pages.Count)) problems.Add($"{number}: stamped file");
                if (new PdfStamper(packedBack).List().Count != 2) problems.Add($"{number}: stamp runs");
                stamped_++;

                if (previous is not null)
                {
                    var merged = PageAssembly.Merge([new MergeSource(PdfDocument.Open(previous), [0]), new MergeSource(PdfDocument.Open(final), [0])]);
                    var mergedBytes = merged.SaveRewrite();
                    if (PdfDocument.Open(mergedBytes).Pages.Count != 2 || !PigOpens(mergedBytes, 2)) problems.Add($"{number}: merge");
                    merged_++;
                }
                previous = final;
            }
            catch (Exception e) when (e is not Xunit.Sdk.XunitException)
            {
                problems.Add($"{number}: {e.GetType().Name} {e.Message}");
            }
        }

        output.WriteLine($"files {files}, refused {refused}, commits {committed}, annotated {annotated}, filled {filled}, stamped {stamped_}, merged {merged_}, deleted {deleted}, PdfPig failed after {pigFailed} (before {pigFailedBefore}), problems {problems.Count}, {timer.Elapsed.TotalSeconds:F0} s");
        foreach (var p in problems.Take(30)) output.WriteLine(p);
        Assert.Empty(problems);
        Assert.Equal(0, pigFailed);
    }

    private static void Commit(PdfEditSession session, string label, List<string> problems, string path, int number)
    {
        if (!session.Commit(label)) problems.Add($"{number}: {label} changed nothing");
    }

    private static bool PigOpens(byte[] bytes, int? pages = null)
    {
        try
        {
            using var pig = Pig.Open(bytes);
            if (pages is not null && pig.NumberOfPages != pages) return false;
            _ = pig.GetPage(1).Text;
            return true;
        }
        catch
        {
            return false;
        }
    }
}
