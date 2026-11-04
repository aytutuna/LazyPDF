using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

internal static class ExportXml
{
    public const string Header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";

    public const long EmuPerPoint = 12700;

    // A .NET string holds 1,073,741,791 characters. A writer that builds its file as one string checks the length as it goes and
    // refuses a document that would pass this, so the failure is a PdfReadException and not an OutOfMemoryException at ToString.
    private const long MaxOutputChars = 1L << 29;

    public static void CheckLength(StringBuilder sb, long coming = 0, long limit = MaxOutputChars)
    {
        if (sb.Length + coming > limit) throw new PdfReadException(PdfReadProblem.Unsupported, ExportText.TooLarge);
    }

    // The characters a picture adds where its bytes are written out at every occurrence.
    public static long Encoded(ExportBlock block, bool hex) => block is ExportPicture picture
        ? hex ? 2L * picture.Image.Data.Length : (picture.Image.Data.Length + 2L) / 3 * 4
        : 0;

    // From Lazy Scan's DocxWriter.cs (EscapeXml): characters XML cannot hold are left out.
    public static string Escape(string text)
    {
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                sb.Append(c).Append(text[i + 1]);
                i++;
                continue;
            }
            if (char.IsSurrogate(c)) continue;
            switch (c)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '"': sb.Append("&quot;"); break;
                case '\t' or '\n' or '\r': sb.Append(c); break;
                default:
                    if (c >= 0x20 && c != '￾' && c != '￿') sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    public static string I(long value) => value.ToString(CultureInfo.InvariantCulture);

    public static string D(double value) => value.ToString("0.##", CultureInfo.InvariantCulture);

    public static byte[] Utf8(string text) => new UTF8Encoding(false).GetBytes(text);

    public static long Emu(double points) => (long)Math.Clamp(Math.Round(points * EmuPerPoint), 1, 1e11);
}
