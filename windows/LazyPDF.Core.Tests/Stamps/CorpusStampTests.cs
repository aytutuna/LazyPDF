using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

// Stamps every file in the list LAZYPDF_CORPUS names (one path per line), saves, reopens, removes
// the stamps again. Does nothing without it; only counts are printed.
public class CorpusStampTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileTakesAllStampsAndLosesThemAgain()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, stamped = 0, pages = 0, skipped = 0, readByPig = 0;
        var failures = new List<string>();
        var fonts = new ArialSource();
        var image = Convert.FromBase64String(StampKit.SampleJpeg);
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            files++;
            try
            {
                using var document = PdfDocument.Open(path);
                if (document.IsSigned || document.Pages.Count == 0 || document.Pages.Count > 400)
                {
                    skipped++;
                    continue;
                }
                int layers = LayerCount(document);
                var stamper = new PdfStamper(document, fonts);
                var jpeg = PdfImageWriter.AddJpeg(document, image)!;
                stamper.AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.95), Image = jpeg, Opacity = 0.2 });
                stamper.AddWatermark(new WatermarkSpec { Text = "TASLAK ŞİİR", Rotation = 45, LayerName = "Watermark" });
                stamper.AddWatermark(new WatermarkSpec { Image = jpeg, Behind = true, Pages = [0] });
                stamper.AddHeaderFooter(new HeaderFooterSpec
                {
                    Header = new("{file}", "", "{date}"),
                    Footer = new("", "Page {page} of {pages}", "{bates}"),
                    FileName = "x.pdf",
                    Bates = new BatesSpec("B", "", 6, 1),
                    Date = new DateTimeOffset(2026, 1, 2, 0, 0, 0, TimeSpan.Zero),
                });
                int runs = stamper.List().Count;
                var bytes = document.SaveRewrite();

                using var reopened = PdfDocument.Open(bytes);
                var again = new PdfStamper(reopened);
                if (again.List().Count != runs || reopened.Pages.Count != document.Pages.Count) failures.Add($"{files}: listing after reopen");
                var incremental = document.SaveIncremental();
                using (var viaUpdate = PdfDocument.Open(incremental)) if (new PdfStamper(viaUpdate).List().Count != runs) failures.Add($"{files}: listing after update");

                again.RemoveAll();
                var clean = reopened.SaveRewrite();
                using var last = PdfDocument.Open(clean);
                if (new PdfStamper(last).List().Count != 0 || LayerCount(last) != layers) failures.Add($"{files}: removal");

                try
                {
                    using var pig = PigDocument.Open(bytes);
                    pig.GetPage(1);
                    readByPig++;
                }
                catch (Exception)
                {
                }
                stamped++;
                pages += document.Pages.Count;
            }
            catch (PdfReadException)
            {
                skipped++;
            }
        }
        output.WriteLine($"{files} files, {stamped} stamped ({pages} pages), {skipped} skipped, {readByPig} read by PdfPig, {failures.Count} failures");
        Assert.Empty(failures);
    }

    private static int LayerCount(PdfDocument document) =>
        document.Array(document.Dict(document.Catalog, "OCProperties"), "OCGs")?.Items.Count ?? 0;
}
