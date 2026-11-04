using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// After Lazy Scan's PdfObjectWriter.cs: the header, numbered objects and streams go straight to a
// stream and the offsets are the caller's to collect. Objects come as PdfObject values now, and
// strings and stream data are encrypted on their way out when the file is.

/// <summary>
/// Writes objects as bytes. <paramref name="position"/> is the offset of the first byte this
/// writer adds (an update starts after the original). With a <paramref name="security"/> the
/// strings and streams of every object are encrypted unless the caller says that object is not
/// (the /Encrypt dictionary).
/// </summary>
internal sealed class PdfObjectWriter(Stream output, long position = 0, PdfSecurity? security = null)
{
    // Text is gathered here and written as Latin-1 once it passes this size, so that an object
    // with a huge array never exists as one string.
    private const int FlushAt = 8192;

    private readonly StringBuilder _text = new();

    /// <summary>The offset the next byte lands at.</summary>
    public long Position { get; private set; } = position;

    /// <summary>"%PDF-version" and the comment of four high bytes that tells transfer programs the file is binary.</summary>
    public void WriteHeader(string version)
    {
        _text.Append("%PDF-").Append(version).Append('\n');
        Flush();
        WriteBytes([(byte)'%', 0xE2, 0xE3, 0xCF, 0xD3, (byte)'\n']);
    }

    /// <summary>A non-stream object; returns the offset it starts at.</summary>
    public long WriteObject(int number, int generation, PdfObject value, bool encrypt = true)
    {
        long at = Begin(number, generation);
        WriteValue(value, number, generation, encrypt && security is not null);
        _text.Append("\nendobj\n");
        Flush();
        return at;
    }

    /// <summary>
    /// A stream object. <paramref name="stored"/> is the data as it is to be stored, filters
    /// applied and not encrypted; /Length is written from what is stored. The cipher is chosen from
    /// <paramref name="cryptView"/>, the dictionary with /Filter and /DecodeParms resolved, when given.
    /// </summary>
    public long WriteStream(int number, int generation, PdfDictionary dictionary, byte[] stored, bool encrypt = true, PdfDictionary? cryptView = null)
    {
        encrypt &= security is not null;
        byte[] data = encrypt ? security!.EncryptStream(number, generation, stored, cryptView ?? dictionary) : stored;
        long at = Begin(number, generation);
        WriteDictionary(dictionary, data.Length, number, generation, encrypt);
        _text.Append("\nstream\n");
        Flush();
        WriteBytes(data);
        _text.Append("\nendstream\nendobj\n");
        Flush();
        return at;
    }

    /// <summary>A value outside any object (the trailer's); nothing in it is encrypted.</summary>
    public void WriteDirect(PdfObject value)
    {
        WriteValue(value, 0, 0, false);
        Flush();
    }

    public void WriteAscii(string text)
    {
        _text.Append(text);
        Flush();
    }

    public void WriteBytes(ReadOnlySpan<byte> bytes)
    {
        output.Write(bytes);
        Position += bytes.Length;
    }

    private long Begin(int number, int generation)
    {
        long at = Position;
        _text.Append(CultureInfo.InvariantCulture, $"{number} {generation} obj\n");
        return at;
    }

    private void WriteValue(PdfObject value, int number, int generation, bool encrypt)
    {
        switch (value)
        {
            case PdfString text when encrypt:
                new PdfString(security!.EncryptString(number, generation, text.Bytes), isHex: true).WriteTo(_text);
                break;
            case PdfArray array:
                _text.Append('[');
                for (int i = 0; i < array.Items.Count; i++)
                {
                    if (i > 0) _text.Append(' ');
                    WriteValue(array.Items[i], number, generation, encrypt);
                }
                _text.Append(']');
                break;
            case PdfDictionary dictionary:
                WriteDictionary(dictionary, null, number, generation, encrypt);
                break;
            default:
                value.WriteTo(_text);
                break;
        }
        if (_text.Length > FlushAt) Flush();
    }

    /// <summary>A dictionary; with <paramref name="length"/> it is a stream's, whose /Length is replaced by that number.</summary>
    private void WriteDictionary(PdfDictionary dictionary, int? length, int number, int generation, bool encrypt)
    {
        // A signature's contents are the signature, not text (ISO 32000-1 7.6.1).
        bool signature = PdfDocument.IsSignature(dictionary);
        _text.Append("<<");
        bool first = true;
        foreach (var (key, item) in dictionary.Entries)
        {
            // Of repeated keys only the last one counts, as the reader has it.
            if (!ReferenceEquals(dictionary[key], item) || (length is not null && key == "Length")) continue;
            if (!first) _text.Append(' ');
            first = false;
            new PdfName(key).WriteTo(_text);
            _text.Append(' ');
            WriteValue(item, number, generation, encrypt && !(signature && key == "Contents"));
        }
        if (length is { } n) _text.Append(first ? "" : " ").Append(CultureInfo.InvariantCulture, $"/Length {n}");
        _text.Append(">>");
    }

    private void Flush()
    {
        Span<byte> buffer = stackalloc byte[512];
        foreach (var chunk in _text.GetChunks())
        {
            var chars = chunk.Span;
            while (!chars.IsEmpty)
            {
                int n = Math.Min(chars.Length, buffer.Length);
                Encoding.Latin1.GetBytes(chars[..n], buffer);
                WriteBytes(buffer[..n]);
                chars = chars[n..];
            }
        }
        _text.Clear();
    }
}
