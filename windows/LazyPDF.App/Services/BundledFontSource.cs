using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>The fonts shipped beside the app (Carlito, Caladea, Liberation), found by family name and style.</summary>
public sealed class BundledFontSource : IFontSource
{
    private readonly string _folder;

    public BundledFontSource(string? folder = null)
    {
        _folder = folder ?? Path.Combine(AppContext.BaseDirectory, "Fonts");
    }

    public FontFile? Find(string family, FontStyles style)
    {
        string face = style switch
        {
            FontStyles.Bold => "Bold",
            FontStyles.Italic => "Italic",
            FontStyles.Bold | FontStyles.Italic => "BoldItalic",
            _ => "Regular",
        };
        string path = Path.Combine(_folder, $"{family.Replace(" ", "")}-{face}.ttf");
        try
        {
            return File.Exists(path) ? new FontFile(File.ReadAllBytes(path)) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
