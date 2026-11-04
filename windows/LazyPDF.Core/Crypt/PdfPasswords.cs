// The preparation is from Lazy Scan's PdfEncryption.cs.
using System.Text;

namespace LazyPDF.Core;

/// <summary>How typed passwords become the bytes the security handler hashes.</summary>
internal static class PdfPasswords
{
    /// <summary>A password is at most this many bytes once prepared (ISO 32000-2 7.6.4.3.3).</summary>
    public const int MaxBytes = 127;

    /// <summary>
    /// R 5 and 6: SASLprep (RFC 4013). Other spaces become U+0020, characters mapped to nothing are
    /// dropped, the rest is NFKC normalized and cut at <see cref="MaxBytes"/> bytes of UTF-8.
    /// </summary>
    public static byte[] Prepare(string password) => Cut(Mapped(password).Normalize(NormalizationForm.FormKC));

    /// <summary>The bytes Apple's PDFKit passes on: <see cref="Prepare"/> with NFKD in place of NFKC.</summary>
    public static byte[] Decompose(string password) => Cut(Mapped(password).Normalize(NormalizationForm.FormKD));

    /// <summary>R 2 to 4 take the password as PDFDocEncoding bytes; Latin-1 stands for it, UTF-8 for text outside it.</summary>
    public static byte[] Legacy(string password) =>
        password.All(c => c < 256) ? Encoding.Latin1.GetBytes(password) : Encoding.UTF8.GetBytes(password);

    private static string Mapped(string password)
    {
        var mapped = new StringBuilder(password.Length);
        foreach (var rune in password.EnumerateRunes())
        {
            int c = rune.Value;
            if (IsNonAsciiSpace(c)) mapped.Append(' ');
            else if (!MapsToNothing(c)) mapped.Append(rune.ToString());
        }
        return mapped.ToString();
    }

    private static byte[] Cut(string text)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(text);
        return utf8.Length <= MaxBytes ? utf8 : utf8[..MaxBytes];
    }

    private static bool IsNonAsciiSpace(int c) =>
        c is 0x00A0 or 0x1680 or (>= 0x2000 and <= 0x200B) or 0x202F or 0x205F or 0x3000;

    private static bool MapsToNothing(int c) =>
        c is 0x00AD or 0x034F or 0x1806 or (>= 0x180B and <= 0x180D) or 0x200C or 0x200D or 0x2060
            or (>= 0xFE00 and <= 0xFE0F) or 0xFEFF;
}
