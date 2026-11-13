using LazyPDF.App.Services;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.App.Tools.Create;

public enum CreateSource
{
    Blank,
    Pictures,
    Text,
    WebPage,
    Office,
}

/// <param name="Files">Picture files to read, in page order; for an Office file, the one file.</param>
/// <param name="Picture">A picture already in memory that stands for <paramref name="Files"/>: the clipboard's.</param>
public sealed record CreateRequest(CreateSource Source, PdfPageSetup Setup, string Title, int Pages = 1, IReadOnlyList<string>? Files = null,
                                   byte[]? Picture = null, string Text = "", double FontSize = 11, string Family = "Arial");

/// <param name="Unreadable">Pictures that could not be read, or letters the font lacks.</param>
/// <param name="Skipped">Pictures or picture frames too large to decode.</param>
/// <param name="Features">What an Office file had that the converter left out.</param>
/// <param name="LeftOutRemote">A web page named parts from the internet that were left out.</param>
public sealed record MadePdf(byte[] Bytes, int Pages, int Unreadable, int Skipped = 0, IReadOnlyList<SkippedFeature>? Features = null, bool LeftOutRemote = false);

public static class PdfMaker
{
    public const int MostBlankPages = 500;

    public const long MostOfficeBytes = 100 << 20;

    internal static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];

    /// <summary>A web page file, drawn by the web view on the window thread; the one source that cannot go through <see cref="Make"/>.</summary>
    public static async Task<MadePdf> MakeWebPageAsync(CreateRequest request, CancellationToken cancel)
    {
        string file = request.Files![0];
        if (new FileInfo(file).Length > WebPageRules.MostBytes) throw new WebPageException(WebPageProblem.TooBig);
        bool remote = await Task.Run(() => WebPageRules.NamesRemoteParts(TextFiles.Decode(File.ReadAllBytes(file))), cancel).WaitAsync(cancel);
        var bytes = await WebPagePdf.RenderAsync(file, request.Setup, cancel);
        int pages = PdfDocument.Open(bytes).Pages.Count;
        if (pages > WebPageRules.MostPages) throw new WebPageException(WebPageProblem.TooLong);
        return new MadePdf(bytes, pages, 0, LeftOutRemote: remote);
    }

    public static MadePdf Make(CreateRequest request, IImageCodec codec, IFontSource fonts, CancellationToken cancel = default)
    {
        switch (request.Source)
        {
            case CreateSource.Blank:
                // A form feed ends a page, so n of them make n empty pages.
                var blank = PdfFromText.Create(new string('\f', request.Pages), fonts, request.Setup, cancellation: cancel);
                return new MadePdf(blank.Bytes, blank.Pages, 0);
            case CreateSource.Pictures:
                var files = request.Picture is { } picture ? [picture] : request.Files!.Select(file =>
                {
                    cancel.ThrowIfCancellationRequested();
                    return File.ReadAllBytes(file);
                }).ToList();
                var pictures = PdfFromPictures.Create(files, codec, request.Setup, cancel);
                return new MadePdf(pictures.Bytes, pictures.Pages, pictures.Unreadable.Count, pictures.SkippedFrames);
            case CreateSource.Office:
                string path = request.Files![0];
                cancel.ThrowIfCancellationRequested();
                if (FileKinds.IsOldOffice(path)) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is in an older Office format.");
                if (new FileInfo(path).Length > MostOfficeBytes) throw new PdfReadException(PdfReadProblem.Unsupported, "The file is over the size limit.");
                var office = new OfficeFontSource(fonts, new BundledFontSource());
                var bytes = File.ReadAllBytes(path);
                var made = FileKinds.OfficeAppOf(path) switch
                {
                    OfficeApp.Excel => OfficeConverter.FromExcel(bytes, office, Path.GetFileName(path), cancel),
                    OfficeApp.PowerPoint => OfficeConverter.FromPowerPoint(bytes, office, codec, cancel),
                    _ => OfficeConverter.FromWord(bytes, office, codec, cancel),
                };
                return new MadePdf(made.Bytes, made.Pages, made.Missing.Count, Features: made.Skipped);
            default:
                var text = PdfFromText.Create(request.Text, fonts, request.Setup, family: request.Family, size: request.FontSize, cancellation: cancel);
                return new MadePdf(text.Bytes, text.Pages, text.Missing.Count);
        }
    }
}
