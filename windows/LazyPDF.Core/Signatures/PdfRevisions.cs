namespace LazyPDF.Core;

/// <summary>One saved state of a file: the bytes up to <paramref name="End"/> are a complete PDF as it stood then. <paramref name="Number"/> counts from 1.</summary>
public sealed record PdfRevision(int Number, int End);

/// <summary>
/// The revisions of a file found by their "%%EOF" lines, not by following the cross-reference chain: a
/// "startxref" that names the start of a cross-reference table or stream and is closed by "%%EOF" ends a revision.
/// The first-page section of a linearized file (offset 0) and such lines inside stream data do not count.
/// </summary>
public static class PdfRevisions
{
    private const int MaxRevisions = 100_000;

    /// <summary>The revisions, oldest first. Empty when the bytes hold no complete one.</summary>
    public static IReadOnlyList<PdfRevision> List(byte[] file)
    {
        var ends = new List<int>();
        var span = file.AsSpan();
        int from = 0;
        while (ends.Count < MaxRevisions)
        {
            int at = span[from..].IndexOf("startxref"u8);
            if (at < 0) break;
            int pos = from + at + "startxref".Length;
            from = pos;
            while (pos < span.Length && PdfLexer.IsWhiteSpace(span[pos])) pos++;
            long offset = 0;
            int digits = 0;
            while (pos < span.Length && span[pos] is >= (byte)'0' and <= (byte)'9' && digits++ < 12) offset = offset * 10 + (span[pos++] - '0');
            while (pos < span.Length && PdfLexer.IsWhiteSpace(span[pos])) pos++;
            if (digits == 0 || offset <= 0 || offset >= file.Length || !span[pos..].StartsWith("%%EOF"u8)) continue;
            if (!StartsSection(file, (int)offset)) continue;
            pos += "%%EOF".Length;
            if (pos < span.Length && span[pos] == 13) pos++;
            if (pos < span.Length && span[pos] == 10) pos++;
            if (ends.Count == 0 || pos > ends[^1]) ends.Add(pos);
        }
        return [.. ends.Select((end, i) => new PdfRevision(i + 1, end))];
    }

    /// <summary>The file cut at the end of <paramref name="revision"/>.</summary>
    public static byte[] Extract(byte[] file, PdfRevision revision) =>
        revision.End > file.Length ? throw new ArgumentOutOfRangeException(nameof(revision)) : file.AsSpan(0, revision.End).ToArray();

    // A table starts with "xref", a stream with "n g obj".
    private static bool StartsSection(byte[] file, int offset)
    {
        var span = file.AsSpan(offset);
        while (!span.IsEmpty && PdfLexer.IsWhiteSpace(span[0])) span = span[1..];
        if (span.StartsWith("xref"u8)) return true;
        var lexer = new PdfLexer(new PdfArrayBytes(file), file.Length - span.Length);
        try
        {
            lexer.ReadObjectHeader();
            return lexer.ReadObject(allowStream: false) is PdfDictionary dictionary && dictionary["Type"] is PdfName { Value: "XRef" };
        }
        catch (PdfReadException)
        {
            return false;
        }
    }
}
