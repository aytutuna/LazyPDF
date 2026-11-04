namespace LazyPDF.Core;

// Stream data. The length is taken from /Length when "endstream" follows it; otherwise from the
// keyword itself, as viewers do.
public sealed partial class PdfDocument
{
    /// <summary>Whitespace tolerated between a stream's declared end and "endstream".</summary>
    private const int EndstreamSlack = 16;

    private int _lastEndstream = -2;
    private int _lastEndobj = -2;
    private readonly HashSet<long> _lengthRepaired = [];

    /// <summary>
    /// The data of <paramref name="stream"/> as stored: decrypted, filters still applied. The array
    /// of a stream whose <see cref="PdfStream.Data"/> was set is that data itself.
    /// </summary>
    public byte[] RawData(PdfStream stream)
    {
        if (stream.Data is { } memory) return memory;
        if (stream.DataOffset < 0 || stream.DataOffset > _data.Length) return [];
        int start = (int)stream.DataOffset;
        byte[] raw = _data.AsSpan(start, StreamLength(stream, start)).ToArray();
        if (_security is null || stream.Number <= 0 || Name(stream.Dictionary, "Type") == "XRef") return raw;
        return _security.DecryptStream(stream.Number, stream.Generation, raw, CryptView(stream.Dictionary));
    }

    /// <summary>
    /// The data of <paramref name="stream"/> decrypted and decoded, with /Length, /Filter and
    /// /DecodeParms resolved first. Throws <see cref="PdfReadException"/> for a filter that is
    /// not supported or data that does not decode.
    /// </summary>
    public byte[] Data(PdfStream stream) => Data(stream, PdfFilters.DefaultMaxSize);

    internal byte[] Data(PdfStream stream, long maxSize, bool strict = false)
    {
        var (filter, parameters, _) = DecodeSpec(stream);
        return PdfFilters.Decode(RawData(stream), filter, parameters, maxSize, strict);
    }

    /// <summary>
    /// The stream's dictionary with /Filter and /DecodeParms direct. The security handler reads them
    /// for the Crypt filter, on writing as on reading, so both must see the same thing.
    /// </summary>
    internal PdfDictionary CryptView(PdfDictionary stream)
    {
        var view = stream.Copy();
        view["Filter"] = Flatten(stream["Filter"], 3);
        view["DecodeParms"] = Flatten(stream["DecodeParms"], 3);
        return view;
    }

    /// <summary>
    /// What the filter layer is given: the resolved /Filter and /DecodeParms of an encrypted file's
    /// stream without the Crypt stage, which the decryption has already carried out. <c>Crypt</c> says there was one.
    /// </summary>
    internal (PdfObject? Filter, PdfObject? Parameters, bool Crypt) DecodeSpec(PdfStream stream)
    {
        var filter = Flatten(stream.Dictionary["Filter"], 2);
        var parameters = Flatten(stream.Dictionary["DecodeParms"], 3);
        if (_security is null) return (filter, parameters, false);
        switch (filter)
        {
            case PdfName { Value: "Crypt" }:
                return (null, null, true);
            case PdfArray array when array.Items.FindIndex(f => f is PdfName { Value: "Crypt" }) is var at and >= 0:
                var rest = new PdfArray([.. array.Items.Where((_, i) => i != at)]);
                if (parameters is PdfArray list && at < list.Items.Count) parameters = new PdfArray([.. list.Items.Where((_, i) => i != at)]);
                return (rest, parameters, true);
            default:
                return (filter, parameters, false);
        }
    }

    private int StreamLength(PdfStream stream, int start)
    {
        // While the cross-reference data is being read an indirect /Length cannot be looked up.
        long? declared = _loadingXref ? (stream.Dictionary["Length"] as PdfNumber)?.Integer : Integer(stream.Dictionary, "Length");
        if (declared is >= 0 && declared <= _data.Length - start && EndstreamFollows(start + (int)declared)) return (int)declared;
        if (_lengthRepaired.Add(stream.DataOffset)) AddRepair($"Stream {stream.Number}: /Length is wrong or missing; its data was taken up to endstream.");
        return FindStreamEnd(start) - start;
    }

    private bool EndstreamFollows(int position)
    {
        int end = Math.Min(position + EndstreamSlack, _data.Length);
        while (position < end && PdfLexer.IsWhiteSpace(_data[position])) position++;
        return _data.AsSpan(position).StartsWith("endstream"u8);
    }

    private int FindStreamEnd(int start)
    {
        int end = IndexFrom("endstream"u8, ref _lastEndstream, start);
        if (end < 0) end = IndexFrom("endobj"u8, ref _lastEndobj, start);
        if (end < 0) end = _data.Length;
        // The line break before the keyword is not data.
        if (end > start && _data[end - 1] == 10) end--;
        if (end > start && _data[end - 1] == 13) end--;
        return end;
    }

    /// <summary>The first <paramref name="pattern"/> at or after <paramref name="start"/>, or -1. Knowing the last one in the file spares a scan to the end for each stream that has none.</summary>
    private int IndexFrom(ReadOnlySpan<byte> pattern, ref int last, int start)
    {
        if (last == -2) last = _data.AsSpan().LastIndexOf(pattern);
        if (last < start) return -1;
        int at = _data.AsSpan(start).IndexOf(pattern);
        return at < 0 ? -1 : start + at;
    }
}
