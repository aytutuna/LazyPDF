using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Reads every structure of every file in a list when LAZYPDF_CORPUS names a text file of paths, and
// writes the outline, labels, metadata and layers back; does nothing otherwise. Only counts are printed.
public class StructureCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryStructureReadsAndTheOutlineSurvivesAWrite()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, outlines = 0, items = 0, named = 0, labelled = 0, attachments = 0, layers = 0, links = 0, scripts = 0, titled = 0;
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
                var facts = DocumentFacts.Read(document);
                if (facts.Metadata.Title is not null) titled++;
                if (facts.HasJavaScript) scripts++;
                attachments += facts.AttachmentCount;
                layers += facts.LayerCount;
                named += PdfDestinations.Named(document).Count;
                if (PdfPageLabels.Read(document).Count > 0) labelled++;
                _ = PdfPageLabels.Labels(document);
                _ = ViewerSettings.Read(document);
                _ = PdfActions.ReadDocument(document);
                _ = PdfPortfolio.Read(document);
                foreach (var page in document.Pages.Take(30)) links += PdfLinks.Read(document, page).Count;
                foreach (var attachment in PdfAttachments.List(document).Take(3)) _ = PdfAttachments.Extract(document, attachment);

                var outline = Outline.Read(document);
                int count = Count(outline.Root);
                items += count;
                if (count > 0) outlines++;
                var titles = Titles(outline.Root);
                outline.Write(document);
                var again = Outline.Read(PdfDocument.Open(document.SaveIncremental()));
                if (!titles.SequenceEqual(Titles(again.Root))) problems.Add($"outline changed in a write ({count} items)");

                var set = PdfLayers.Read(document);
                if (set.Layers.Count > 0) PdfLayers.SetVisible(document, set.Layers[0].Reference, !set.Layers[0].IsOn);
                DocumentMetadata.Read(document).Write(document);
                ViewerSettings.Read(document).Write(document);
                PdfPageLabels.Write(document, PdfPageLabels.Read(document));
                _ = PdfDocument.Open(document.SaveIncremental());
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                problems.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"{files} files, {titled} titled, {outlines} with bookmarks ({items} items), {named} named destinations, {labelled} with labels, " +
                         $"{attachments} attachments, {layers} layers, {links} links on first pages, {scripts} with scripts");
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    private static int Count(OutlineItem item) => item.Children.Sum(c => 1 + Count(c));

    private static List<string> Titles(OutlineItem item) => [.. item.Children.SelectMany(c => new[] { c.Title }.Concat(Titles(c)))];
}
