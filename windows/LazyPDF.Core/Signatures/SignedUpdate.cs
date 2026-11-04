using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core;

// The signed update: the document's changes written as an incremental update with a zeroed /Contents and
// /ByteRange, then the byte range filled in, the file digested outside /Contents and the signature put in the gap.
internal static class SignedUpdate
{
    private const int MaxReserve = 1 << 21;
    private static readonly byte[] ByteRangeText = Encoding.ASCII.GetBytes("[0 0000000000 0000000000 0000000000]");

    /// <summary>The ByteRange entry a signature dictionary starts with; <see cref="Fill"/> overwrites its numbers in the written file.</summary>
    public static PdfArray ByteRangePlaceholder() =>
        new([new PdfNumber(0), new PdfNumber("0000000000"), new PdfNumber("0000000000"), new PdfNumber("0000000000")]);

    /// <summary>
    /// Writes the update for <paramref name="document"/>, whose signature dictionary holds
    /// <paramref name="contents"/> (the zero bytes that reserve the room), and returns the whole file with the signature in
    /// it. <paramref name="sign"/> turns the digest of the signed ranges into the bytes of /Contents; the room grows when they do not fit.
    /// </summary>
    public static byte[] Build(PdfDocument document, PdfString contents, HashAlgorithmName digest, Func<byte[], byte[]> sign)
    {
        while (true)
        {
            byte[] file = Fill(document, contents, digest, sign, out bool fits);
            if (fits) return file;
            if (contents.Bytes.Length >= MaxReserve) throw new InvalidOperationException(SignatureText.NoRoom);
            contents.Bytes = new byte[contents.Bytes.Length * 2];
        }
    }

    private static byte[] Fill(PdfDocument document, PdfString contents, HashAlgorithmName digest, Func<byte[], byte[]> sign, out bool fits)
    {
        byte[] update = PdfUpdate.Build(document);
        var source = document.Source.Span;
        byte[] file = new byte[source.Length + update.Length];
        source.CopyTo(file);
        update.CopyTo(file.AsSpan(source.Length));

        byte[] hex = new byte[contents.Bytes.Length * 2 + 2];
        hex.AsSpan().Fill((byte)'0');
        hex[0] = (byte)'<';
        hex[^1] = (byte)'>';
        int start = IndexIn(file, source.Length, hex);
        int rangeAt = IndexIn(file, source.Length, ByteRangeText);
        if (start < 0 || rangeAt < 0) throw new InvalidOperationException("The signature placeholders were not written.");
        int end = start + hex.Length;

        string range = $"[0 {start:D10} {end:D10} {file.Length - end:D10}]";
        Encoding.ASCII.GetBytes(range, file.AsSpan(rangeAt));

        byte[] signature = sign(RangeDigest(file, start, end, digest));
        fits = signature.Length <= contents.Bytes.Length;
        if (fits) Encoding.ASCII.GetBytes(Convert.ToHexString(signature), file.AsSpan(start + 1));
        return file;
    }

    public static byte[] RangeDigest(byte[] file, int gapStart, int gapEnd, HashAlgorithmName algorithm)
    {
        using var hash = IncrementalHash.CreateHash(algorithm);
        hash.AppendData(file.AsSpan(0, gapStart));
        hash.AppendData(file.AsSpan(gapEnd));
        return hash.GetHashAndReset();
    }

    private static int IndexIn(byte[] file, int from, byte[] pattern)
    {
        int at = file.AsSpan(from).IndexOf(pattern);
        return at < 0 ? -1 : from + at;
    }
}
