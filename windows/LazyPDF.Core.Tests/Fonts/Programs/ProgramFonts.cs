namespace LazyPDF.Core.Tests;

/// <summary>Installed fonts the program tests read. A missing file gives null and the test returns early.</summary>
internal static class ProgramFonts
{
    private static readonly string[] OtfCandidates =
    [
        @"C:\Program Files\Android\Android Studio\jbr\lib\fonts\Inter-Regular.otf",
        "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
    ];

    private static readonly string[] NamedCandidates =
    [
        @"C:\Program Files\Android\Android Studio\jbr\lib\fonts\DroidSerif-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ];

    /// <summary>A TrueType font whose post table (format 2) carries glyph names; the Windows system fonts use format 3.</summary>
    public static byte[]? Named()
    {
        foreach (var path in NamedCandidates)
            if (File.Exists(path)) return File.ReadAllBytes(path);
        return null;
    }

    public static byte[]? Windows(string name)
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), name);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    public static byte[]? Otf()
    {
        foreach (var path in OtfCandidates)
            if (File.Exists(path)) return File.ReadAllBytes(path);
        return null;
    }

    /// <summary>Position of a table's directory entry in a plain sfnt file, -1 when absent.</summary>
    public static int DirectoryEntry(byte[] font, string tag)
    {
        var count = (font[4] << 8) | font[5];
        for (var i = 0; i < count; i++)
        {
            var at = 12 + 16 * i;
            if (System.Text.Encoding.ASCII.GetString(font, at, 4) == tag) return at;
        }
        return -1;
    }

    public static int TableOffset(byte[] font, string tag)
    {
        var e = DirectoryEntry(font, tag);
        return e < 0 ? -1 : (font[e + 8] << 24) | (font[e + 9] << 16) | (font[e + 10] << 8) | font[e + 11];
    }
}
