namespace LazyPDF.Core;

/// <summary>A signature dictionary as it stands in the file bytes at <paramref name="Offset"/>, the start of its "n g obj".</summary>
internal sealed record FoundSignature(int Number, long Offset, PdfDictionary Dictionary);

// Signature dictionaries are found by their /ByteRange in the bytes themselves, not through the form, so a
// signature a later revision unhooked from its field is still seen. They are never in object streams (12.8.1).
internal static class SignatureScan
{
    private const int MaxFound = 512;
    private const int HeaderReach = 1 << 20;
    private static readonly byte[] Key = "/ByteRange"u8.ToArray();

    public static List<FoundSignature> Find(byte[] file)
    {
        var found = new List<FoundSignature>();
        var seen = new HashSet<long>();
        var bytes = new PdfArrayBytes(file);
        int from = 0;
        while (found.Count < MaxFound)
        {
            int at = file.AsSpan(from).IndexOf(Key);
            if (at < 0) break;
            int pos = from + at;
            from = pos + Key.Length;
            if (ObjectStart(file, pos) is not { } start || !seen.Add(start)) continue;
            try
            {
                var lexer = new PdfLexer(bytes, start);
                var (number, _) = lexer.ReadObjectHeader();
                if (lexer.ReadObject(allowStream: false) is PdfDictionary { } dictionary && lexer.Position > pos
                    && dictionary["ByteRange"] is PdfArray && dictionary["Contents"] is PdfString { IsHex: true })
                {
                    found.Add(new FoundSignature(number, start, dictionary));
                }
            }
            catch (PdfReadException)
            {
                // A "/ByteRange" inside stream data or a broken object is not a signature.
            }
        }
        return found;
    }

    // The last "n g obj" before the dictionary.
    private static long? ObjectStart(byte[] file, int pos)
    {
        int low = Math.Max(0, pos - HeaderReach);
        var window = file.AsSpan(low, pos - low);
        while (true)
        {
            int obj = window.LastIndexOf("obj"u8);
            if (obj < 0) return null;
            int i = obj;
            if (i > 0 && window[i - 1] == (byte)'d') // endobj
            {
                window = window[..obj];
                continue;
            }
            while (i > 0 && PdfLexer.IsWhiteSpace(window[i - 1])) i--;
            int generationEnd = i;
            while (i > 0 && window[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
            if (i == generationEnd) { window = window[..obj]; continue; }
            while (i > 0 && PdfLexer.IsWhiteSpace(window[i - 1])) i--;
            int numberEnd = i;
            while (i > 0 && window[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
            if (i == numberEnd) { window = window[..obj]; continue; }
            return low + i;
        }
    }
}
