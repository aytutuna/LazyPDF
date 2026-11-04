using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// The byte range of a signature checked against the file: four numbers, the first range from 0, the gap exactly
/// the hex string of /Contents in the signature's own object, the second range running to the end of a revision.
/// </summary>
internal sealed record SignedRanges(int GapStart, int GapEnd, int End, PdfRevision Revision, byte[] Contents)
{
    public byte[] Digest(byte[] file, HashAlgorithmName algorithm)
    {
        using var hash = IncrementalHash.CreateHash(algorithm);
        hash.AppendData(file.AsSpan(0, GapStart));
        hash.AppendData(file.AsSpan(GapEnd, End - GapEnd));
        return hash.GetHashAndReset();
    }

    /// <summary>The ranges, or null when they are not what a signature may cover.</summary>
    public static SignedRanges? Check(byte[] file, FoundSignature found, IReadOnlyList<PdfRevision> revisions)
    {
        if (found.Dictionary["ByteRange"] is not PdfArray { Items.Count: 4 } array) return null;
        var numbers = new long[4];
        for (int i = 0; i < 4; i++)
        {
            if (array.Items[i] is not PdfNumber { IsInteger: true, Integer: { } value and >= 0 }) return null;
            numbers[i] = value;
        }
        long a = numbers[1], b = numbers[2], end = numbers[2] + numbers[3];
        if (numbers[0] != 0 || a <= found.Offset || b <= a + 1 || end > file.Length || end <= b - 1) return null;
        if (file[a] != (byte)'<' || file[b - 1] != (byte)'>') return null;

        byte[]? decoded = DecodeHex(file.AsSpan((int)a + 1, (int)(b - a - 2)));
        if (decoded is null || found.Dictionary["Contents"] is not PdfString { Bytes: var declared } || !declared.AsSpan().SequenceEqual(decoded)) return null;
        int objectEnd = file.AsSpan((int)b).IndexOf("endobj"u8);
        if (objectEnd < 0) return null;

        // The second range ends where a revision does (a few blank bytes after its "%%EOF" aside), and the
        // signature's object is inside that revision and not an earlier one.
        for (int i = 0; i < revisions.Count; i++)
        {
            var revision = revisions[i];
            if (revision.End < end || revision.End - end > 2 || !file.AsSpan((int)end, revision.End - (int)end).ToArray().All(c => PdfLexer.IsWhiteSpace(c))) continue;
            long start = i == 0 ? 0 : revisions[i - 1].End;
            if (found.Offset < start || found.Offset >= end) return null;
            return new SignedRanges((int)a, (int)b, (int)end, revision, decoded);
        }
        return null;
    }

    private static byte[]? DecodeHex(ReadOnlySpan<byte> hex)
    {
        if (hex.Length % 2 != 0) return null;
        var result = new byte[hex.Length / 2];
        for (int i = 0; i < result.Length; i++)
        {
            int high = Nibble(hex[2 * i]), low = Nibble(hex[2 * i + 1]);
            if (high < 0 || low < 0) return null;
            result[i] = (byte)(high << 4 | low);
        }
        return result;
    }

    private static int Nibble(byte c) => c switch
    {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        _ => -1,
    };
}
