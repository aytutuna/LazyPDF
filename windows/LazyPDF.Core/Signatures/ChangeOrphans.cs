namespace LazyPDF.Core;

internal sealed partial class ChangeDetector
{
    // An "n g obj" after the signed revision that no cross-reference section lists, for a number the signed
    // revision uses: a viewer that scans the file instead of trusting the table (or a repair) would take it for the object.
    private void Orphans()
    {
        var source = _b.Source.Span;
        int from = _a.Length;
        var listed = new HashSet<(int, long)>();
        foreach (var document in _between!.Append(_b))
        {
            foreach (var (n, entry) in document.Entries)
            {
                if (entry.Kind == PdfDocument.EntryKind.InUse) listed.Add((n, entry.Offset));
            }
        }
        var streams = new List<(long Start, long End)>();
        foreach (var (n, entry) in _b.Entries)
        {
            if (entry.Kind == PdfDocument.EntryKind.InUse && entry.Offset >= from && _b.Get(n) is PdfStream stream)
            {
                // The length the reader used, which is not the declared one when that does not land on endstream.
                streams.Add((stream.DataOffset, stream.DataOffset + _b.RawData(stream).Length));
            }
        }

        int pos = from;
        while (pos < source.Length)
        {
            int at = source[pos..].IndexOf("obj"u8);
            if (at < 0) break;
            int obj = pos + at;
            pos = obj + 3;
            if (obj == 0 || source[obj - 1] == (byte)'d' || !TryHeader(source, obj, from, out int number, out int start)) continue;
            if (streams.Any(r => start >= r.Start && start < r.End)) continue;
            // A listed object is still shadowed when a later revision took the entry back to an earlier offset.
            if (listed.Contains((number, start)) && !(_b.Entries.TryGetValue(number, out var current) && current.Kind == PdfDocument.EntryKind.InUse && current.Offset < start)) continue;
            if (_a.Entries.TryGetValue(number, out var existing) && existing.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed)
            {
                Report(InContent(number) ? SignatureChangeKind.PageContent : SignatureChangeKind.Other, number, allowed: false);
            }
        }
    }

    // "n g " just before "obj", not glued to what precedes it: a scanning viewer takes it from mid-line as well.
    private static bool TryHeader(ReadOnlySpan<byte> source, int obj, int floor, out int number, out int start)
    {
        number = 0;
        start = 0;
        int i = obj;
        if (i == 0 || !PdfLexer.IsWhiteSpace(source[i - 1])) return false;
        while (i > floor && PdfLexer.IsWhiteSpace(source[i - 1])) i--;
        int digitsEnd = i;
        while (i > floor && source[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
        if (i == digitsEnd || !PdfLexer.IsWhiteSpace(source[i - 1])) return false;
        while (i > floor && PdfLexer.IsWhiteSpace(source[i - 1])) i--;
        int numberEnd = i;
        while (i > floor && source[i - 1] is >= (byte)'0' and <= (byte)'9') i--;
        if (i == numberEnd || (i > floor && !PdfLexer.IsWhiteSpace(source[i - 1]) && !PdfLexer.IsDelimiter(source[i - 1]))) return false;
        start = i;
        var digits = source[i..numberEnd].TrimStart((byte)'0');
        return digits.Length <= 9 && int.TryParse(digits.IsEmpty ? "0"u8 : digits, out number);
    }
}
