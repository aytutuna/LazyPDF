namespace LazyPDF.Core;

/// <summary>ASCIIHexDecode, ASCII85Decode and RunLengthDecode (ISO 32000-1 7.4.2, 7.4.3, 7.4.5).</summary>
internal static class AsciiFilters
{
    public static byte[] DecodeHex(byte[] data, long maxSize)
    {
        var output = new FilterBuffer(maxSize, data.Length / 2);
        int high = -1;
        foreach (byte b in data)
        {
            if (b == '>') break;
            if (PdfLexer.IsWhiteSpace(b)) continue;
            int digit = HexValue(b);
            if (digit < 0) throw PdfReadException.Damaged("ASCIIHexDecode data holds a character that is not a hex digit.");
            if (high < 0)
            {
                high = digit;
            }
            else
            {
                output.Add((byte)(high << 4 | digit));
                high = -1;
            }
        }
        // An odd last digit stands for a digit and a zero.
        if (high >= 0) output.Add((byte)(high << 4));
        return output.ToArray();
    }

    public static byte[] Decode85(byte[] data, long maxSize)
    {
        var output = new FilterBuffer(maxSize, data.Length);
        int start = data.Length >= 2 && data[0] == '<' && data[1] == '~' ? 2 : 0;
        Span<byte> group = stackalloc byte[5];
        int count = 0;
        for (int i = start; i < data.Length; i++)
        {
            byte b = data[i];
            if (b == '~') break;
            if (PdfLexer.IsWhiteSpace(b)) continue;
            if (b == 'z' && count == 0)
            {
                output.Append(4).Clear();
                continue;
            }
            if (b is < (byte)'!' or > (byte)'u') throw PdfReadException.Damaged("ASCII85Decode data holds a character outside ! to u.");
            group[count++] = (byte)(b - '!');
            if (count == 5)
            {
                Emit(group, 5, output);
                count = 0;
            }
        }
        // A short last group of n characters gives n - 1 bytes; a lone character gives none.
        if (count > 1)
        {
            for (int i = count; i < 5; i++) group[i] = 84;
            Emit(group, count, output);
        }
        return output.ToArray();
    }

    private static void Emit(ReadOnlySpan<byte> group, int characters, FilterBuffer output)
    {
        uint value = 0;
        foreach (byte digit in group) value = unchecked(value * 85 + digit);
        Span<byte> four = [(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value];
        output.Add(four[..(characters - 1)]);
    }

    public static byte[] DecodeRunLength(byte[] data, long maxSize)
    {
        var output = new FilterBuffer(maxSize, data.Length * 2);
        int i = 0;
        while (i < data.Length)
        {
            int length = data[i++];
            if (length == 128) break;
            if (length < 128)
            {
                int count = Math.Min(length + 1, data.Length - i);
                output.Add(data.AsSpan(i, count));
                i += count;
            }
            else if (i < data.Length)
            {
                output.Append(257 - length).Fill(data[i++]);
            }
        }
        return output.ToArray();
    }

    private static int HexValue(byte b) => b switch
    {
        >= (byte)'0' and <= (byte)'9' => b - '0',
        >= (byte)'a' and <= (byte)'f' => b - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => b - 'A' + 10,
        _ => -1,
    };
}
