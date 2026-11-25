using System.Globalization;
using System.Text;

namespace LazyPDF.App.Tools.Create;

public static class TextFiles
{
    /// <summary>The most a text box takes before typing in it stalls.</summary>
    public const int MostBytes = 1 << 20;

    /// <summary>The most a text file can be; one over what the box takes is kept aside and not shown.</summary>
    public const int MostFileBytes = 20 << 20;

    public static string Filter => Loc.T("Text files") + "|*.txt;*.md;*.csv;*.log;*.json;*.xml;*.ini";

    /// <summary>UTF-8 or a byte order mark's encoding; anything else is read in the code page this PC's language uses, Windows-1254 for Turkish.</summary>
    public static string Decode(byte[] bytes)
    {
        try
        {
            using var reader = new StreamReader(new MemoryStream(bytes), new UTF8Encoding(false, true), detectEncodingFromByteOrderMarks: true);
            return reader.ReadToEnd();
        }
        catch (DecoderFallbackException)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage).GetString(bytes);
        }
    }
}
