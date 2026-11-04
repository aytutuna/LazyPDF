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
        if (HasBadHexString(data)) Add("6.1.6", PdfAText.Trailer, PdfAText.HexString);
        if (_doc.XrefRebuilt) Add("6.1.4", PdfAText.Xref, PdfAText.XrefDamaged);
        if (IsPart1)
        {
            if (_doc.XrefIsStream) Add("6.1.4", PdfAText.Xref, PdfAText.XrefStream);
            if (_doc.Entries.Values.Any(e => e.Kind == PdfDocument.EntryKind.Compressed)) Add("6.1.4", PdfAText.Xref, PdfAText.ObjectStreams);
        }
        else
        {
            CheckObjectStreams();
        }
    }

    // Nothing refers to an object stream as a value, so the walk of the objects never meets one; the strings in it are read here.
    private void CheckObjectStreams()
    {
        foreach (int number in _doc.Entries.Values.Where(e => e.Kind == PdfDocument.EntryKind.Compressed).Select(e => e.StreamNumber).Distinct())
        {
            if (OverBudget) return;
            if (_doc.Get(number) is not PdfStream stream) continue;
            try
            {
                byte[] data = _doc.Data(stream, MaxStreamBytes);
                _work += data.Length;
                if (HasBadHexString(data)) Add("6.1.6", PdfAText.ObjectName(number), PdfAText.HexString);
            }
            catch (PdfReadException)
            {
            }
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
        int keyword = start >= 2 && data[start - 1] == 10 ? (data[start - 2] == 13 ? start - 2 : start - 1) : -1;
        if (keyword < 6 || !data[(keyword - 6)..keyword].SequenceEqual("stream"u8)) Add("6.1.7", where, PdfAText.StreamKeyword);

        long? declared = _doc.Integer(stream.Dictionary, "Length");
        if (declared is not >= 0 || declared > data.Length - start)
        {
            Add("6.1.7", where, PdfAText.StreamLength);
            return;
        }
        int end = start + (int)declared;
        int after = end < data.Length && data[end] == 13 ? (end + 1 < data.Length && data[end + 1] == 10 ? end + 2 : end + 1) : end < data.Length && data[end] == 10 ? end + 1 : end;
        if (after == end || !data[after..].StartsWith("endstream"u8)) Add("6.1.7", where, PdfAText.StreamLength);
    }

    // 6.1.6: a hex string has an even number of hex digits and nothing but white space besides. The parser drops the difference, so this
    // reads the bytes outside the stream data. In a content stream, given as its parsed operations, the data of an inline image is skipped to where the parser found its end.
    internal static bool HasBadHexString(ReadOnlySpan<byte> data, IReadOnlyList<ContentOperation>? content = null)
    {
        var images = content?.Where(o => o.Image is not null).GetEnumerator();
        for (int i = 0; i < data.Length; i++)
        {
            byte c = data[i];
            if (c == '%')
            {
                while (i < data.Length && data[i] is not (10 or 13)) i++;
            }
            else if (c == '(')
            {
                for (int depth = 0; i < data.Length; i++)
                {
                    if (data[i] == '\\') i++;
                    else if (data[i] == '(') depth++;
                    else if (data[i] == ')' && --depth == 0) break;
                }
            }
            else if (c == '<' && i + 1 < data.Length && data[i + 1] == '<')
            {
                i++;
            }
            else if (c == '<')
            {
                int digits = 0;
                for (i++; i < data.Length && data[i] != '>'; i++)
                {
                    if (Uri.IsHexDigit((char)data[i])) digits++;
                    else if (data[i] is not (0 or 9 or 10 or 12 or 13 or 32)) return true;
                }
                if (digits % 2 != 0) return true;
            }
            else if (IsRegular(c) || c == '/')
            {
                int from = c == '/' ? i + 1 : i, end = from;
                while (end < data.Length && IsRegular(data[end])) end++;
                if (c != '/' && data[from..end].SequenceEqual("stream"u8))
                {
                    int close = data[end..].IndexOf("endstream"u8);
                    end = close < 0 ? data.Length : end + close;
                }
                else if (images is not null && c != '/' && data[from..end].SequenceEqual("ID"u8) && images.MoveNext())
                {
                    end = Math.Max(end, Math.Min(images.Current.End, data.Length));
                }
                i = Math.Max(i, end - 1);
            }
        }
        return false;
    }

    private static bool IsRegular(byte c) => c is not (0 or 9 or 10 or 12 or 13 or 32 or (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%');
}
