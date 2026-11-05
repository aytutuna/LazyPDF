using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Export;

/// <summary>The document as the export reads it: the bytes at the time, and what is needed to open them again.</summary>
public sealed record ExportSource(byte[] Pdf, string? Password, X509Certificate2? Certificate, IPageRenderer Renderer, IImageCodec Codec, string Stem);

public static class Exporter
{
    // The sheets XlsxWriter stops at.
    private const int MostSheets = 1000;

    /// <summary>False when the file was opened with a password that does not allow copying content out.</summary>
    public static bool Allowed(PdfDocument document) =>
        document.Security is not { OpenedAsOwner: false } security || security.Permissions.HasFlag(PdfPermissions.Copy);

    public static ExportSource Source(DocumentTab tab, IImageCodec codec) =>
        new(tab.Session.Current.ToArray(), tab.Password, tab.Certificate, tab.Renderer, codec, Path.GetFileNameWithoutExtension(tab.Title));

    /// <summary>
    /// A renderer on its own copy of the bytes. The tab's renderer follows Undo and Redo, which stay open to the toolbar
    /// during an export, so pictures of pages would come from two states of the file. Null when the system cannot read the copy.
    /// </summary>
    public static WindowsPageRenderer? Snapshot(ExportSource source)
    {
        var session = source.Certificate is { } certificate ? PdfEditSession.Open(source.Pdf, certificate) : PdfEditSession.Open(source.Pdf, source.Password);
        var renderer = new WindowsPageRenderer();
        if (renderer.Load(session, source.Password)) return renderer;
        renderer.Dispose();
        return null;
    }

    /// <summary>Writes to <paramref name="target"/>: a file, or a folder for pictures. Runs off the UI thread.</summary>
    public static ExportResult Write(ExportSource source, ExportOptions options, string target, CancellationToken cancel)
    {
        var document = source.Certificate is { } certificate ? PdfDocument.Open(source.Pdf, certificate) : PdfDocument.Open(source.Pdf, source.Password);
        if (options.Format == ExportFormat.Pictures) return Pictures(document, source, options, target, cancel);
        if (options.Format == ExportFormat.Images) return Images(document, source, options, target, cancel);

        var model = ExportLayout.Analyze(document, options.Pages, source.Codec, cancel);
        cancel.ThrowIfCancellationRequested();
        if (!model.Pages.Any(p => p.Lines.Count > 0)) return new ExportResult(0, target, Gap: ExportGap.NoText);
        switch (options.Format)
        {
            case ExportFormat.Word: Save(target, DocxWriter.Make(model)); break;
            case ExportFormat.Excel: Save(target, XlsxWriter.Make(model)); break;
            case ExportFormat.PowerPoint: Save(target, PptxWriter.Make(model)); break;
            case ExportFormat.Html: SaveText(target, options.FixedHtml ? HtmlWriter.Fixed(model) : HtmlWriter.Reflowed(model)); break;
            case ExportFormat.Markdown: SaveText(target, MarkdownWriter.Make(model, options.MarkdownPictures)); break;
            case ExportFormat.Rtf: SaveText(target, RtfWriter.Make(model)); break;
            default: SaveText(target, PlainTextWriter.Make(model)); break;
        }
        return new ExportResult(1, target, Gap: options.Format == ExportFormat.Excel ? ExcelGap(model) : ExportGap.None, PicturesLeftOut: model.PicturesLeftOut);
    }

    // With tables a workbook has a sheet for each table and none for the text around them, otherwise a sheet for each page.
    internal static ExportGap ExcelGap(ExportDocument model)
    {
        if (!model.Tables.Any()) return model.Pages.Count > MostSheets ? ExportGap.PastSheetLimit : ExportGap.None;
        if (model.Pages.Any(p => p.Blocks.OfType<ExportParagraph>().Any())) return ExportGap.OutsideTables;
        return model.Tables.Count() > MostSheets ? ExportGap.PastSheetLimit : ExportGap.None;
    }

    private static ExportResult Pictures(PdfDocument document, ExportSource source, ExportOptions options, string folder, CancellationToken cancel)
    {
        var pages = options.Pages ?? [.. Enumerable.Range(0, document.Pages.Count)];
        int digits = document.Pages.Count.ToString().Length;
        string extension = options.Picture == PictureFormat.Png ? ".png" : ".jpg";
        int written = 0, skipped = 0;
        foreach (int page in pages)
        {
            cancel.ThrowIfCancellationRequested();
            byte[]? bytes = options.Picture == PictureFormat.Png
                ? PageImages.Png(source.Renderer, page, options.Dpi)
                : PageImages.Jpeg(source.Renderer, source.Codec, page, options.Dpi, options.Quality);
            if (bytes is null)
            {
                skipped++;
                continue;
            }
            Save(Unique(folder, $"{source.Stem} page {(page + 1).ToString().PadLeft(digits, '0')}{extension}"), bytes);
            written++;
        }
        return new ExportResult(written, folder, skipped);
    }

    // One page at a time: the extractor holds every picture of a call in memory under one budget, which a long scan would use up.
    private static ExportResult Images(PdfDocument document, ExportSource source, ExportOptions options, string folder, CancellationToken cancel)
    {
        int written = 0;
        foreach (int page in options.Pages ?? [.. Enumerable.Range(0, document.Pages.Count)])
        {
            foreach (var image in ImageExtractor.Extract(document, [page], source.Codec, cancel))
            {
                cancel.ThrowIfCancellationRequested();
                Save(Unique(folder, image.FileName), image.Image.Data);
                written++;
            }
        }
        return new ExportResult(written, folder);
    }

    // A file written beside others never goes over one that is there.
    private static string Unique(string folder, string name)
    {
        string path = Path.Combine(folder, name);
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{stem} ({n}){extension}");
        return path;
    }

    private static void SaveText(string path, string text) => Save(path, new UTF8Encoding(false).GetBytes(text));

    private static void Save(string path, byte[] bytes)
    {
        string temp = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            File.Delete(temp);
            throw;
        }
    }
}
