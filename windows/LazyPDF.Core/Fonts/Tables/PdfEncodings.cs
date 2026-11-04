namespace LazyPDF.Core;

/// <summary>
/// The predefined encodings of ISO 32000-1 Annex D, as 256 glyph names indexed by character code;
/// a code the encoding leaves unassigned holds null.
/// </summary>
public static class PdfEncodings
{
    public static IReadOnlyList<string?> Standard { get; } = Array.AsReadOnly(Parse(EncodingData.Standard));

    /// <summary>The codes Annex D leaves unused show a bullet, as the table's footnote says.</summary>
    public static IReadOnlyList<string?> WinAnsi { get; } = Array.AsReadOnly(Parse(EncodingData.WinAnsi));

    public static IReadOnlyList<string?> MacRoman { get; } = Array.AsReadOnly(Parse(EncodingData.MacRoman));

    public static IReadOnlyList<string?> MacExpert { get; } = Array.AsReadOnly(Parse(EncodingData.MacExpert));

    /// <summary>PDFDocEncoding, the one of text strings outside content streams (Annex D.3).</summary>
    public static IReadOnlyList<string?> PdfDoc { get; } = Array.AsReadOnly(Parse(EncodingData.PdfDoc));

    /// <summary>The built-in encoding of the Symbol font.</summary>
    public static IReadOnlyList<string?> Symbol { get; } = Array.AsReadOnly(Parse(EncodingData.Symbol));

    /// <summary>The built-in encoding of ZapfDingbats.</summary>
    public static IReadOnlyList<string?> ZapfDingbats { get; } = Array.AsReadOnly(Parse(EncodingData.ZapfDingbats));

    /// <summary>The encoding a font's /Encoding name stands for, or null for a name that is none of them.</summary>
    public static IReadOnlyList<string?>? ByName(string pdfName) => pdfName switch
    {
        "StandardEncoding" => Standard,
        "WinAnsiEncoding" => WinAnsi,
        "MacRomanEncoding" => MacRoman,
        "MacExpertEncoding" => MacExpert,
        "PDFDocEncoding" => PdfDoc,
        _ => null,
    };

    /// <summary>The first code of <paramref name="encoding"/> that shows the glyph, or -1.</summary>
    public static int CodeOf(IReadOnlyList<string?> encoding, string glyphName)
    {
        for (int code = 0; code < encoding.Count; code++)
            if (encoding[code] == glyphName)
                return code;
        return -1;
    }

    static string?[] Parse(string runs)
    {
        var names = new string?[256];
        int code = 0;
        foreach (var token in runs.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            string name = token;
            int eq = token.IndexOf('=');
            if (eq > 0)
            {
                code = int.Parse(token.AsSpan(0, eq));
                name = token[(eq + 1)..];
            }
            names[code++] = name;
        }
        return names;
    }
}
