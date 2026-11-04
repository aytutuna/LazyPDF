namespace LazyPDF.Core;

/// <summary>
/// One saved state of a file that was updated incrementally: the file cut at byte
/// <paramref name="End"/> is a complete PDF as it stood then. <paramref name="Number"/> counts from
/// 1 for the oldest.
/// </summary>
public sealed record PdfVersion(int Number, int End)
{
    /// <summary>
    /// The versions in a document's bytes, oldest first: each cross-reference section the newest
    /// one leads back to, with the end of the "%%EOF" that closes it. A "%%EOF" counts only when the
    /// "startxref" before it names the section, so the first-page section of a linearized file,
    /// whose "startxref" is 0, is not a version. A rebuilt document has none.
    /// </summary>
    internal static List<PdfVersion> Find(PdfDocument document)
    {
        var bytes = document.Source.Span;
        var ends = new Dictionary<long, int>();
        int from = 0;
        while (from < bytes.Length)
        {
            int at = bytes[from..].IndexOf("startxref"u8);
            if (at < 0) break;
            int pos = from + at + "startxref".Length;
            from = pos;
            long offset = 0;
            while (pos < bytes.Length && PdfLexer.IsWhiteSpace(bytes[pos])) pos++;
            int digits = 0;
            while (pos < bytes.Length && bytes[pos] is >= (byte)'0' and <= (byte)'9' && digits++ < 15) offset = offset * 10 + (bytes[pos++] - '0');
            while (pos < bytes.Length && PdfLexer.IsWhiteSpace(bytes[pos])) pos++;
            if (digits == 0 || !bytes[pos..].StartsWith("%%EOF"u8)) continue;
            pos += "%%EOF".Length;
            if (pos < bytes.Length && bytes[pos] == 13) pos++;
            if (pos < bytes.Length && bytes[pos] == 10) pos++;
            ends[offset] = pos;
        }

        var versions = new List<PdfVersion>();
        foreach (long section in document.SectionOffsets.Reverse())
        {
            if (ends.TryGetValue(section, out int end) && (versions.Count == 0 || end > versions[^1].End))
            {
                versions.Add(new PdfVersion(versions.Count + 1, end));
            }
        }
        return versions;
    }
}
