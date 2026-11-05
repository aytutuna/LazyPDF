using LazyPDF.Core;

namespace LazyPDF.App.Tools.Optimize;

public enum SizePreset { Small, Balanced, High, Custom }

/// <summary>The settings behind the Custom preset.</summary>
internal sealed record CustomSize(int ImageDpi, int JpegQuality, bool TrimFonts, bool BlackWhite, bool DropAppData, bool DropPrivateKeys)
{
    public static CustomSize Default { get; } = new(150, 75, true, true, true, false);
}

internal sealed record OptimizeChoice(SizePreset Preset, CustomSize Custom, bool Grayscale, bool FastWebView)
{
    public OptimizeOptions Options(PdfSecurity? security)
    {
        var options = Preset switch
        {
            SizePreset.Small => OptimizeOptions.For(OptimizePreset.Small),
            SizePreset.Balanced => OptimizeOptions.For(OptimizePreset.Balanced),
            SizePreset.High => OptimizeOptions.For(OptimizePreset.HighQuality),
            _ => new OptimizeOptions
            {
                ImageDpi = Custom.ImageDpi,
                ImageDpiAbove = Custom.ImageDpi * 3 / 2,
                JpegQuality = Custom.JpegQuality,
                BilevelTolerance = Custom.BlackWhite ? 8 : -1,
                SubsetFonts = Custom.TrimFonts,
                StripPieceInfo = Custom.DropAppData,
                StripPrivateData = Custom.DropPrivateKeys,
            },
        };
        return options with { Grayscale = Grayscale, Security = security };
    }
}
