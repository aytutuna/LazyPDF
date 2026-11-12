using System.IO.Compression;

namespace LazyPDF.Core;

// From Lazy Scan's PdfFilters.cs, extended to the whole filter set of ISO 32000-1 7.4.

/// <summary>A stream's data with its filters undone up to an image codec; <see cref="Codec"/> is null when none is left.</summary>
public sealed record PdfDecodedStream(byte[] Data, string? Codec, PdfDictionary? Parameters);

/// <summary>The stream filters (ISO 32000-1 7.4) and the predictors that go with Flate and LZW.</summary>
public static class PdfFilters
{
    /// <summary>The most a filter chain may expand to unless the caller says otherwise.</summary>
    public const long DefaultMaxSize = 256L << 20;

    private const int MaxColors = 1 << 16;

    /// <summary>
    /// The data of a stream with its filters undone. Both arguments are resolved: a name or an
    /// array of names, a dictionary or an array of them. An image codec (DCT, JPX, JBIG2) is
    /// <see cref="PdfReadProblem.Unsupported"/> here; see <see cref="DecodeToCodec"/>.
    /// </summary>
    public static byte[] Decode(byte[] data, PdfObject? filter, PdfObject? parameters) =>
        Decode(data, filter, parameters, DefaultMaxSize);

    /// <summary>As <see cref="Decode(byte[], PdfObject?, PdfObject?)"/>, with output that may not pass <paramref name="maxSize"/> bytes.</summary>
    public static byte[] Decode(byte[] data, PdfObject? filter, PdfObject? parameters, long maxSize) =>
        Decode(data, filter, parameters, maxSize, strict: false);

    /// <summary>With <paramref name="strict"/> a Flate stream that breaks off or does not decode cleanly is damage, not a short result.</summary>
    internal static byte[] Decode(byte[] data, PdfObject? filter, PdfObject? parameters, long maxSize, bool strict) =>
        Run(data, filter, parameters, maxSize, stopAtCodec: false, strict).Data;

    /// <summary>
    /// Undoes the filters before an image codec and stops there: the bytes are the codec's input
    /// (a JPEG file, say), with the codec's name ("DCTDecode", "JPXDecode" or "JBIG2Decode") and its
    /// /DecodeParms. Without a codec in the chain the data is fully decoded and the name is null.
    /// </summary>
    public static PdfDecodedStream DecodeToCodec(byte[] data, PdfObject? filter, PdfObject? parameters, long maxSize = DefaultMaxSize) =>
        Run(data, filter, parameters, maxSize, stopAtCodec: true, strict: false);

    private static PdfDecodedStream Run(byte[] data, PdfObject? filter, PdfObject? parameters, long maxSize, bool stopAtCodec, bool strict)
    {
        List<string> filters = filter switch
        {
            null or PdfNull => [],
            PdfName name => [name.Value],
            PdfArray array => array.Items.Select(i => (i as PdfName)?.Value ?? "").ToList(),
            _ => throw PdfReadException.Damaged("A stream's /Filter is not a name."),
        };
        List<PdfDictionary?> parameterList = parameters switch
        {
            PdfArray array => array.Items.Select(i => i as PdfDictionary).ToList(),
            PdfDictionary dictionary => [dictionary],
            _ => [],
        };
        for (int i = 0; i < filters.Count; i++)
        {
            var decodeParms = i < parameterList.Count ? parameterList[i] : null;
            switch (filters[i])
            {
                case "FlateDecode" or "Fl":
                    data = Predict(Inflate(data, maxSize, strict), decodeParms);
                    break;
                case "LZWDecode" or "LZW":
                    data = Predict(LzwCodec.Decode(data, Int(decodeParms?["EarlyChange"], 1) != 0, maxSize), decodeParms);
                    break;
                case "ASCIIHexDecode" or "AHx":
                    data = AsciiFilters.DecodeHex(data, maxSize);
                    break;
                case "ASCII85Decode" or "A85":
                    data = AsciiFilters.Decode85(data, maxSize);
                    break;
                case "RunLengthDecode" or "RL":
                    data = AsciiFilters.DecodeRunLength(data, maxSize);
                    break;
                case "CCITTFaxDecode" or "CCF":
                    data = DecodeCcitt(data, decodeParms, maxSize);
                    break;
                case "Crypt":
                    // Decryption is the document layer's; /Identity leaves the data alone (ISO 32000-1 7.4.10).
                    if ((decodeParms?["Name"] as PdfName)?.Value is not (null or "Identity"))
                        throw new PdfReadException(PdfReadProblem.Unsupported, "A named crypt filter reached the filter layer.");
                    break;
                case "DCTDecode" or "DCT" or "JPXDecode" or "JBIG2Decode":
                    if (!stopAtCodec) throw new PdfReadException(PdfReadProblem.Unsupported, $"The /{filters[i]} filter is an image codec.");
                    string codec = filters[i] == "DCT" ? "DCTDecode" : filters[i];
                    return new PdfDecodedStream(data, codec, decodeParms);
                default:
                    throw new PdfReadException(PdfReadProblem.Unsupported, $"The /{filters[i]} filter is not supported.");
            }
        }
        return new PdfDecodedStream(data, null, null);
    }

    private static byte[] DecodeCcitt(byte[] data, PdfDictionary? p, long maxSize)
    {
        int columns = Int(p?["Columns"], 1728);
        if (columns is < 1 or > 1 << 20) throw PdfReadException.Damaged("A CCITT stream has /Columns out of range.");
        return Ccitt.Decode(data, Int(p?["K"], 0), columns, Math.Max(0, Int(p?["Rows"], 0)),
            Bool(p?["EncodedByteAlign"]), Bool(p?["EndOfLine"]), Bool(p?["BlackIs1"]), maxSize);
    }

    /// <summary>
    /// zlib data inflated; raw deflate data (no zlib header) is accepted too. Data that breaks
    /// off or fails its checksum gives what decoded before the break; nothing decoded is damage.
    /// </summary>
    public static byte[] Inflate(byte[] data) => Inflate(data, DefaultMaxSize);

    public static byte[] Inflate(byte[] data, long maxSize) => Inflate(data, maxSize, strict: false);

    /// <summary>A raw deflate stream (a zip entry) inflated; a stream that breaks off or does not inflate is damage.</summary>
    public static byte[] InflateRaw(byte[] data, long maxSize)
    {
        var output = new FilterBuffer(maxSize, (int)Math.Min(data.Length * 4L, 1 << 22));
        if (!InflateFrom(data, 0, output, strict: true)) throw PdfReadException.Damaged("A compressed stream does not inflate.");
        return output.ToArray();
    }

    private static byte[] Inflate(byte[] data, long maxSize, bool strict)
    {
        if (data.Length == 0) return [];
        var output = new FilterBuffer(maxSize, (int)Math.Min(data.Length * 4L, 1 << 22));
        // The deflate stream is read bare, past a valid zlib header: the Adler-32 check would throw away
        // the last block of a file whose checksum is wrong (ISO 32000-1 7.4.4).
        int header = data.Length >= 2 && (data[0] & 0x0F) == 8 && (data[0] * 256 + data[1]) % 31 == 0 ? 2 : 0;
        bool clean = InflateFrom(data, header, output, strict);
        if (output.Count == 0 && !clean && header > 0) clean = InflateFrom(data, 0, output, strict);
        if (output.Count == 0 && !clean) throw PdfReadException.Damaged("A compressed stream does not inflate.");
        return output.ToArray();
    }

    private static bool InflateFrom(byte[] data, int start, FilterBuffer output, bool strict)
    {
        using var input = new EndWatch(data, start);
        using var d = new DeflateStream(input, CompressionMode.Decompress);
        bool pumped = Pump(d, output, strict);
        // DeflateStream reports a stream that breaks off as the end of its data. It asks its source for more
        // input only when the final block has not ended, so a source that ran dry shows the break.
        if (strict && output.Count > 0 && input.RanDry) throw PdfReadException.Damaged("A compressed stream breaks off.");
        return pumped && !input.RanDry;
    }

    private sealed class EndWatch(byte[] data, int start) : MemoryStream(data, start, data.Length - start)
    {
        public bool RanDry { get; private set; }

        public override int Read(byte[] buffer, int offset, int count) => Watch(base.Read(buffer, offset, count), count);

        public override int Read(Span<byte> buffer) => Watch(base.Read(buffer), buffer.Length);

        private int Watch(int read, int asked)
        {
            if (read == 0 && asked > 0) RanDry = true;
            return read;
        }
    }

    private static bool Pump(Stream source, FilterBuffer output, bool strict)
    {
        try
        {
            while (true)
            {
                var room = output.Reserve(1 << 16);
                int read = source.Read(room);
                if (read == 0) break;
                output.Commit(read);
            }
            return true;
        }
        catch (InvalidDataException) when (strict && output.Count > 0)
        {
            throw PdfReadException.Damaged("A compressed stream breaks off.");
        }
        catch (InvalidDataException)
        {
            return false;
        }
    }

    /// <summary>
    /// Undoes a /Predictor (ISO 32000-1 7.4.4.4): 2 (TIFF) or 10-15 (PNG, each row with its own
    /// filter byte), at 1, 2, 4, 8 or 16 bits per component. A last row cut short is kept as far as it goes.
    /// </summary>
    public static byte[] Predict(byte[] data, PdfDictionary? parameters)
    {
        int predictor = Int(parameters?["Predictor"], 1);
        if (predictor <= 1 || data.Length == 0) return data;
        int colors = Math.Max(1, Int(parameters?["Colors"], 1));
        if (colors > MaxColors) throw PdfReadException.Damaged($"A predictor with {colors} colors.");
        int bitsPerComponent = Int(parameters?["BitsPerComponent"], 8);
        int columns = Math.Max(1, Int(parameters?["Columns"], 1));
        if (bitsPerComponent is not (1 or 2 or 4 or 8 or 16)) throw PdfReadException.Damaged($"A predictor with {bitsPerComponent} bits per component.");
        if (predictor != 2 && predictor < 10) throw new PdfReadException(PdfReadProblem.Unsupported, $"Predictor {predictor} is not supported.");
        // A row longer than the data is one short row; this keeps a bad /Columns from allocating.
        long rowBits = (long)colors * bitsPerComponent * columns;
        int rowLength = (int)Math.Min((rowBits + 7) / 8, data.Length);
        return predictor == 2
            ? PredictTiff(data, rowLength, colors, bitsPerComponent, columns)
            : PredictPng(data, rowLength, (int)Math.Min((colors * (long)bitsPerComponent + 7) / 8, rowLength));
    }

    private static byte[] PredictTiff(byte[] data, int rowLength, int colors, int bits, int columns)
    {
        var output = (byte[])data.Clone();
        for (int start = 0; start < output.Length; start += rowLength)
        {
            var row = output.AsSpan(start, Math.Min(rowLength, output.Length - start));
            switch (bits)
            {
                case 8:
                    for (int i = colors; i < row.Length; i++) row[i] += row[i - colors];
                    break;
                case 16:
                    for (int i = colors * 2; i + 1 < row.Length; i += 2)
                    {
                        int sum = ((row[i] << 8) | row[i + 1]) + ((row[i - colors * 2] << 8) | row[i - colors * 2 + 1]);
                        row[i] = (byte)(sum >> 8);
                        row[i + 1] = (byte)sum;
                    }
                    break;
                default:
                    long count = Math.Min((long)columns * colors, row.Length * 8L / bits);
                    int mask = (1 << bits) - 1;
                    for (long j = colors; j < count; j++)
                    {
                        int sum = Component(row, j, bits) + Component(row, j - colors, bits);
                        int shift = 8 - bits - (int)(j * bits % 8);
                        int at = (int)(j * bits / 8);
                        row[at] = (byte)((row[at] & ~(mask << shift)) | ((sum & mask) << shift));
                    }
                    break;
            }
        }
        return output;
    }

    private static int Component(ReadOnlySpan<byte> row, long index, int bits) =>
        (row[(int)(index * bits / 8)] >> (8 - bits - (int)(index * bits % 8))) & ((1 << bits) - 1);

    private static byte[] PredictPng(byte[] data, int rowLength, int bytesPerPixel)
    {
        bytesPerPixel = Math.Max(1, bytesPerPixel);
        int step = rowLength + 1;
        int rem = data.Length % step;
        var output = new byte[(data.Length / step) * rowLength + Math.Max(rem - 1, 0)];
        var zeros = new byte[rowLength];
        int at = 0, written = 0, previous = -1;
        while (at < data.Length - 1)
        {
            int type = data[at++];
            int n = Math.Min(rowLength, data.Length - at);
            var row = output.AsSpan(written, n);
            data.AsSpan(at, n).CopyTo(row);
            ReadOnlySpan<byte> up = previous >= 0 ? output.AsSpan(previous, n) : zeros.AsSpan(0, n);
            // Other row filter bytes leave the row as it is, as other readers do.
            switch (type)
            {
                case 1:
                    for (int i = bytesPerPixel; i < n; i++) row[i] += row[i - bytesPerPixel];
                    break;
                case 2:
                    for (int i = 0; i < n; i++) row[i] += up[i];
                    break;
                case 3:
                    for (int i = 0; i < n; i++) row[i] += (byte)(((i >= bytesPerPixel ? row[i - bytesPerPixel] : 0) + up[i]) / 2);
                    break;
                case 4:
                    for (int i = 0; i < n; i++)
                    {
                        bool inside = i >= bytesPerPixel;
                        row[i] += (byte)Paeth(inside ? row[i - bytesPerPixel] : 0, up[i], inside ? up[i - bytesPerPixel] : 0);
                    }
                    break;
            }
            previous = written;
            written += n;
            at += n;
        }
        return output;
    }

    private static int Paeth(int a, int b, int c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    internal static int Int(PdfObject? value, int fallback) =>
        value is PdfNumber { Integer: { } n } && n is >= int.MinValue and <= int.MaxValue ? (int)n : fallback;

    internal static bool Bool(PdfObject? value) => value is PdfBoolean { Value: true };
}
