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
    Word,
}

/// <param name="Files">Picture files to read, in page order; for a Word file, the one file.</param>
/// <param name="Picture">A picture already in memory that stands for <paramref name="Files"/>: the clipboard's.</param>
public sealed record CreateRequest(CreateSource Source, PdfPageSetup Setup, string Title, int Pages = 1, IReadOnlyList<string>? Files = null,
                                   byte[]? Picture = null, string Text = "", double FontSize = 11, string Family = "Arial");

/// <param name="Unreadable">Pictures that could not be read, or letters the font lacks.</param>
/// <param name="Skipped">Pictures or picture frames too large to decode.</param>
/// <param name="Features">What a Word file had that the converter left out.</param>
public sealed record MadePdf(byte[] Bytes, int Pages, int Unreadable, int Skipped = 0, IReadOnlyList<SkippedFeature>? Features = null);

public static class PdfMaker
{
    public const int MostBlankPages = 500;

    public const long MostWordBytes = 100 << 20;

    internal static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];

    /// <summary>A web page file, drawn by the web view on the window thread; the one source that cannot go through <see cref="Make"/>.</summary>
    public static async Task<MadePdf> MakeWebPageAsync(CreateRequest request, CancellationToken cancel)
    {
        var bytes = await WebPagePdf.RenderAsync(request.Files![0], request.Setup, cancel);
        return new MadePdf(bytes, PdfDocument.Open(bytes).Pages.Count, 0);
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
            case CreateSource.Word:
                string path = request.Files![0];
                cancel.ThrowIfCancellationRequested();
                if (new FileInfo(path).Length > MostWordBytes) throw new PdfReadException(PdfReadProblem.Unsupported, "The Word file is over the size limit.");
                var word = OfficeConverter.FromWord(File.ReadAllBytes(path), new OfficeFontSource(fonts, new BundledFontSource()), codec, cancel);
                return new MadePdf(word.Bytes, word.Pages, word.Missing.Count, Features: word.Skipped);
            default:
                var text = PdfFromText.Create(request.Text, fonts, request.Setup, family: request.Family, size: request.FontSize, cancellation: cancel);
                return new MadePdf(text.Bytes, text.Pages, text.Missing.Count);
        }
    }
}
