using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

public enum CreateSource
{
    Blank,
    Pictures,
    Text,
}

/// <param name="Files">Picture files to read, in page order.</param>
/// <param name="Picture">A picture already in memory that stands for <paramref name="Files"/>: the clipboard's.</param>
public sealed record CreateRequest(CreateSource Source, PdfPageSetup Setup, string Title, int Pages = 1, IReadOnlyList<string>? Files = null,
                                   byte[]? Picture = null, string Text = "", double FontSize = 11, string Family = "Arial",
                                   double? Width = null, double? Height = null);

/// <param name="Unreadable">Pictures that could not be read, or letters the font lacks.</param>
public sealed record MadePdf(byte[] Bytes, int Pages, int Unreadable);

public static class PdfMaker
{
    public const int MostBlankPages = 500;

    internal static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];

    public static MadePdf Make(CreateRequest request, IImageCodec codec, IFontSource fonts, CancellationToken cancel = default)
    {
        switch (request.Source)
        {
            case CreateSource.Blank:
                // A form feed ends a page, so n of them make n empty pages.
                var blank = PdfFromText.Create(new string('\f', request.Pages), fonts, request.Setup, cancellation: cancel);
                if (request.Width is not { } width || request.Height is not { } height) return new MadePdf(blank.Bytes, blank.Pages, 0);
                var sized = PdfDocument.Open(blank.Bytes);
                (width, height) = request.Setup.Orientation switch
                {
                    PdfOrientation.Landscape => (Math.Max(width, height), Math.Min(width, height)),
                    PdfOrientation.Portrait => (Math.Min(width, height), Math.Max(width, height)),
                    _ => (width, height),
                };
                PageOperations.Resize(sized, Enumerable.Range(0, sized.Pages.Count), width, height, ResizeMode.ChangeBox);
                return new MadePdf(sized.SaveRewrite(), blank.Pages, 0);
            case CreateSource.Pictures:
                var files = request.Picture is { } picture ? [picture] : request.Files!.Select(file =>
                {
                    cancel.ThrowIfCancellationRequested();
                    return File.ReadAllBytes(file);
                }).ToList();
                var pictures = PdfFromPictures.Create(files, codec, request.Setup, cancel);
                return new MadePdf(pictures.Bytes, pictures.Pages, pictures.Unreadable.Count);
            default:
                var text = PdfFromText.Create(request.Text, fonts, request.Setup, family: request.Family, size: request.FontSize, cancellation: cancel);
                return new MadePdf(text.Bytes, text.Pages, text.Missing.Count);
        }
    }
}
