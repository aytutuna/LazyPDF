using System.Globalization;
using System.Text;

namespace LazyPDF.App.Tools.Create;

public static class TextFiles
{
    /// <summary>The most a text box takes before typing in it stalls.</summary>
    public const int MostBytes = 1 << 20;

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
