namespace LazyPDF.Core.Office;

/// <summary>
/// The font lookup of the converter: the font a document names, if it is installed; else the bundled font with
/// the same metrics, so lines and pages break where Word broke them; else the bundled default.
/// </summary>
public sealed class OfficeFontSource : IFontSource
{
    public const string DefaultFamily = "Carlito";

    // Office name (lower case) to the bundled family that has the same advance widths.
    private static readonly Dictionary<string, string> Compatible = new()
    {
        ["calibri"] = "Carlito",
        ["cambria"] = "Caladea",
        ["arial"] = "Liberation Sans",
        ["helvetica"] = "Liberation Sans",
        ["times new roman"] = "Liberation Serif",
        ["times"] = "Liberation Serif",
        ["courier new"] = "Liberation Mono",
        ["courier"] = "Liberation Mono",
    };

    private readonly IFontSource? _installed;
    private readonly IFontSource? _bundled;
    private readonly Dictionary<(string, FontStyles), FontFile> _loaded = [];

    public OfficeFontSource(IFontSource? installed, IFontSource? bundled)
    {
        _installed = installed;
        _bundled = bundled;
    }

    /// <summary>The installed source's shaper, if it has one; its files are the ones it can shape.</summary>
    public IShaper? Shaper => _installed as IShaper;

    public FontFile? Find(string family, FontStyles style)
    {
        if (_installed?.Find(family, style) is { } installed) return installed;
        if (_bundled is null) return null;
        // A document that names a bundled family itself (Carlito) gets it as it is.
        string bundled = Compatible.GetValueOrDefault(Fold(family), family);
        return FindBundled(bundled, style) ?? FindBundled(DefaultFamily, style);
    }

    // Names the bundled source does not know all end up at the default; handing back the same file keeps a document
    // with thousands of made-up names from reading and parsing the default font once per name.
    private FontFile? FindBundled(string family, FontStyles style)
    {
        if (_loaded.TryGetValue((family, style), out var known)) return known;
        var file = _bundled!.Find(family, style);
        if (file is not null) _loaded[(family, style)] = file;
        return file;
    }

    // Only A-Z fold, so the Swift twin matches without depending on its own case tables.
    private static string Fold(string name) =>
        string.Create(name.Length, name, (span, s) =>
        {
            for (int i = 0; i < s.Length; i++) span[i] = s[i] is >= 'A' and <= 'Z' ? (char)(s[i] + 32) : s[i];
        });
}
