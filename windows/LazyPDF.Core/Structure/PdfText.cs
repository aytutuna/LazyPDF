using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Text strings (ISO 32000-1 7.9.2.2): PDFDocEncoding, UTF-16BE with a byte order mark, and
/// UTF-8 with one (PDF 2.0). Every title, author, label and description in the file is one.
/// </summary>
public static class PdfText
{
    private static readonly Lazy<(string[] Decode, Dictionary<char, byte> Encode)> Tables = new(BuildTables);

    /// <summary>The text of the bytes; a language escape (7.9.2.2) is dropped.</summary>
    public static string Decode(ReadOnlySpan<byte> bytes)
    {
        string text;
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) text = Encoding.BigEndianUnicode.GetString(bytes[2..]);
        else if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) text = Encoding.Unicode.GetString(bytes[2..]);
        else if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) text = Encoding.UTF8.GetString(bytes[3..]);
        else
        {
            var table = Tables.Value.Decode;
            var sb = new StringBuilder(bytes.Length);
            foreach (byte b in bytes) sb.Append(table[b]);
            return sb.ToString();
        }
        return StripLanguage(text);
    }

    /// <summary>The smallest correct form: PDFDocEncoding when every character is in it, UTF-16BE with a byte order mark otherwise.</summary>
    public static byte[] Encode(string text)
    {
        var encode = Tables.Value.Encode;
        var bytes = new byte[text.Length];
        for (int i = 0; i < text.Length; i++)
        {
            if (!encode.TryGetValue(text[i], out bytes[i]))
            {
                var wide = Encoding.BigEndianUnicode.GetBytes(text);
                return [0xFE, 0xFF, .. wide];
            }
        }
        return bytes;
    }

    /// <summary>The /F string of a file specification, which is bytes and not a text string: ASCII, with _ for the rest (/UF has the real name).</summary>
    internal static PdfString ToFileName(string name) =>
        new([.. name.Select(c => c is >= ' ' and <= '~' ? (byte)c : (byte)'_')], false);

    /// <summary>A string object for the text, in hex when it holds bytes a literal would have to escape.</summary>
    public static PdfString ToObject(string text)
    {
        var bytes = Encode(text);
        return new PdfString(bytes, bytes.Any(b => b < 0x20 || b >= 0x7F));
    }

    /// <summary>The text a value stands for: a string, or a stream's decoded data (JavaScript may be either). Null for anything else.</summary>
    public static string? Read(PdfDocument document, PdfObject? value) => document.Resolve(value) switch
    {
        PdfString s => Decode(s.Bytes),
        PdfStream s => TryData(document, s),
        _ => null,
    };

    public static string? Read(PdfDocument document, PdfDictionary? dictionary, string key) => Read(document, dictionary?[key]);

    private static string? TryData(PdfDocument document, PdfStream stream)
    {
        try
        {
            return Decode(document.Data(stream));
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private static string StripLanguage(string text)
    {
        int start = text.IndexOf('\u001B');
        if (start < 0) return text;
        var sb = new StringBuilder(text.Length);
        int at = 0;
        while (start >= 0)
        {
            sb.Append(text, at, start - at);
            int end = text.IndexOf('\u001B', start + 1);
            if (end < 0) return sb.ToString();
            at = end + 1;
            start = text.IndexOf('\u001B', at);
        }
        return sb.Append(text, at, text.Length - at).ToString();
    }

    private static (string[], Dictionary<char, byte>) BuildTables()
    {
        var decode = new string[256];
        var encode = new Dictionary<char, byte>();
        var names = PdfEncodings.PdfDoc;
        for (int code = 0; code < 256; code++)
        {
            // Codes the encoding leaves out read as Latin-1, which is what most writers meant.
            string? text = names[code] is { } name ? GlyphList.UnicodeOf(name) : null;
            decode[code] = text is { Length: 1 } ? text : ((char)code).ToString();
            if (text is { Length: 1 } || code is 9 or 10 or 13) encode.TryAdd(decode[code][0], (byte)code);
        }
        return (decode, encode);
    }
}
