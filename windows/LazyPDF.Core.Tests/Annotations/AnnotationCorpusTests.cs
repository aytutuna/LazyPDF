using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Reads the annotations of every file in a list when LAZYPDF_CORPUS names a text file of paths, moves
// them through FDF and XFDF, adds one of ours and flattens a copy; does nothing otherwise. Only counts are printed.
public class AnnotationCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileReadsExportsAndTakesANewAnnotation()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, annotated = 0, annotations = 0, comments = 0, replies = 0, exported = 0, flattened = 0, imported = 0, changed = 0;
        var problems = new List<string>();
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
                continue;
            }
            files++;
            try
            {
                var all = PdfAnnotations.ReadAll(document);
                annotations += all.Count;
                if (all.Count > 0) annotated++;
                var thread = PdfComments.List(document);
                comments += thread.Count;
                replies += thread.Sum(c => c.Replies.Count);
                foreach (var order in Enum.GetValues<CommentOrder>()) _ = PdfComments.List(document, null, order);

                var fdf = PdfFdf.Export(document);
                exported += fdf.Annotations.Count;
                var again = PdfFdf.Read(PdfFdf.Write(fdf));
                if (again.Annotations.Count != fdf.Annotations.Count) problems.Add("FDF lost annotations");
                var xfdf = PdfXfdf.Read(PdfXfdf.Write(fdf));
                if (xfdf.Annotations.Count != fdf.Annotations.Count) problems.Add("XFDF lost annotations");
                imported += PdfFdf.Import(PdfDocument.Open(TestPdf.Simple(Math.Max(1, document.Pages.Count))), again).Imported;

                var page = document.Pages[0];
                var writer = new PdfAnnotationWriter(document);
                var box = page.CropBox;
                writer.AddTextMarkup(page, AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(box.Left + 10, box.Bottom + 10, box.Left + 100, box.Bottom + 24))]);
                writer.AddFreeText(page, new PdfRect(box.Left + 10, box.Bottom + 40, box.Left + 150, box.Bottom + 80), "Test");
                foreach (var found in all.Where(a => a.Reference is not null && a.Type is not (AnnotationType.Widget or AnnotationType.Popup)).Take(8))
                {
                    try
                    {
                        var moved = writer.Move(found, 5, 5);
                        moved = writer.Resize(moved, new PdfRect(moved.Rect.Left, moved.Rect.Bottom, moved.Rect.Left + moved.Rect.Width + 10, moved.Rect.Bottom + moved.Rect.Height + 10));
                        writer.SetOpacity(writer.SetColor(moved, [0, 0.5, 1]), 0.8);
                        changed++;
                    }
                    catch (InvalidOperationException)
                    {
                        // Text no Standard 14 font can draw, and no font source given.
                    }
                }
                var edited = PdfDocument.Open(document.SaveIncremental());
                if (PdfAnnotations.Read(edited, edited.Pages[0]).Count != PdfAnnotations.Read(document, page).Count) problems.Add("an annotation was lost in a save");

                flattened += PdfAnnotationFlattener.FlattenAll(edited);
                _ = PdfDocument.Open(edited.SaveRewrite());
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                problems.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"{files} files, {annotated} with annotations ({annotations} in all), {comments} comments with {replies} replies, " +
                         $"{exported} exported to FDF, {imported} imported again, {changed} edited, {flattened} flattened");
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }
}
