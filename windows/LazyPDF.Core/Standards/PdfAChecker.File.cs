using System.Text;

namespace LazyPDF.Core;

// File structure: header, trailer, cross-reference form and the syntax of streams (ISO 19005-1 6.1,
// 19005-2 6.1). These look at the bytes, because the reader tolerates what the standard does not.
internal sealed partial class PdfAChecker
{
    private void CheckFile()
    {
        var data = _doc.Source.Span;
        if (_doc.Repairs.Any(r => r.StartsWith("Cut ", StringComparison.Ordinal))) Add("6.1.2", PdfAText.Header, PdfAText.BytesBeforeHeader);
        CheckHeader(data);
        CheckTrailer(data);
        if (_doc.XrefRebuilt) Add("6.1.4", PdfAText.Xref, PdfAText.XrefDamaged);
        if (IsPart1)
        {
            if (_doc.XrefIsStream) Add("6.1.4", PdfAText.Xref, PdfAText.XrefStream);
            if (_doc.Entries.Values.Any(e => e.Kind == PdfDocument.EntryKind.Compressed)) Add("6.1.4", PdfAText.Xref, PdfAText.ObjectStreams);
        }
    }

    private void CheckHeader(ReadOnlySpan<byte> data)
    {
        int eol = data.IndexOfAny((byte)10, (byte)13);
        if (eol < 0 || eol > 32)
        {
            Add("6.1.2", PdfAText.Header, PdfAText.HeaderMissing);
            return;
        }
        string version = Encoding.Latin1.GetString(data[5..eol]).Trim();
        bool good = Part == 4 ? version == "2.0" : version.Length == 3 && version[0] == '1' && version[1] == '.' && version[2] is >= '0' and <= '7';
        if (!good) Add("6.1.2", PdfAText.Header, Part == 4 ? PdfAText.HeaderVersion4(version) : PdfAText.HeaderVersion(version));

        int next = eol + (data[eol] == 13 && eol + 1 < data.Length && data[eol + 1] == 10 ? 2 : 1);
        bool binary = next + 5 <= data.Length && data[next] == (byte)'%' && data.Slice(next + 1, 4).ToArray().All(b => b > 127);
        if (!binary) Add("6.1.2", PdfAText.Header, PdfAText.HeaderComment);
    }

    private void CheckTrailer(ReadOnlySpan<byte> data)
    {
        int eof = data.LastIndexOf("%%EOF"u8);
        if (eof < 0)
        {
            Add("6.1.3", PdfAText.Trailer, PdfAText.NoEof);
        }
        else
        {
            var tail = data[(eof + 5)..];
            if (!(tail.IsEmpty || tail is [10] or [13] or [13, 10])) Add("6.1.3", PdfAText.Trailer, PdfAText.DataAfterEof);
        }
        if (_doc.Id.Count < 2 || _doc.Id.Any(i => i.Length == 0)) Add("6.1.3", PdfAText.Trailer, PdfAText.NoId);
        if (_doc.IsEncrypted) Add("6.1.3", PdfAText.Trailer, PdfAText.Encrypted);
    }

    /// <summary>The keyword line before the data and the bytes after it (6.1.7 in part 1, 6.1.7.1 in part 2).</summary>
    private void CheckStreamSyntax(PdfStream stream, string where)
    {
        if (stream.DataOffset < 0 || stream.DataOffset > _doc.Source.Length) return;
        var data = _doc.Source.Span;
        int start = (int)stream.DataOffset;
        bool lf = start > 0 && data[start - 1] == 10;
        if (!lf) Add("6.1.7", where, PdfAText.StreamKeyword);

        long? declared = _doc.Integer(stream.Dictionary, "Length");
        if (declared is not >= 0 || declared > data.Length - start)
        {
            Add("6.1.7", where, PdfAText.StreamLength);
            return;
        }
        int end = start + (int)declared;
        int after = end < data.Length && data[end] == 13 ? (end + 1 < data.Length && data[end + 1] == 10 ? end + 2 : end + 1) : end < data.Length && data[end] == 10 ? end + 1 : end;
        if (!data[after..].StartsWith("endstream"u8)) Add("6.1.7", where, PdfAText.StreamLength);
    }
}
