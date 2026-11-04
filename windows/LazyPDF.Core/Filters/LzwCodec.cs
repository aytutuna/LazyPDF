namespace LazyPDF.Core;

/// <summary>LZWDecode (ISO 32000-1 7.4.4): codes of 9 to 12 bits, most significant first, 256 clears the table, 257 ends the data.</summary>
internal static class LzwCodec
{
    private const int Clear = 256, End = 257, First = 258, TableSize = 4096;

    /// <summary>Corrupt data (a code beyond the table) ends the output where it is.</summary>
    public static byte[] Decode(byte[] data, bool earlyChange, long maxSize)
    {
        var output = new FilterBuffer(maxSize, data.Length * 3);
        var prefix = new int[TableSize];
        var suffix = new byte[TableSize];
        var first = new byte[TableSize];
        var length = new int[TableSize];
        for (int i = 0; i < 256; i++)
        {
            suffix[i] = first[i] = (byte)i;
            length[i] = 1;
        }
        int early = earlyChange ? 1 : 0;
        int bits = 9, next = First, previous = -1;
        uint pending = 0;
        int pendingBits = 0;
        foreach (byte b in data)
        {
            pending = pending << 8 | b;
            pendingBits += 8;
            while (pendingBits >= bits)
            {
                int code = (int)(pending >> (pendingBits - bits)) & ((1 << bits) - 1);
                pendingBits -= bits;
                pending &= (1u << pendingBits) - 1;
                if (code == Clear)
                {
                    bits = 9;
                    next = First;
                    previous = -1;
                    continue;
                }
                if (code == End) return output.ToArray();
                if (previous < 0)
                {
                    if (code > 255) return output.ToArray();
                    output.Add((byte)code);
                    previous = code;
                    continue;
                }
                byte head;
                if (code < next && (code < 256 || code >= First))
                {
                    head = first[code];
                    Write(output, code, prefix, suffix, length);
                }
                else if (code == next && next < TableSize)
                {
                    head = first[previous];
                    Entry(next, previous, head, prefix, suffix, first, length);
                    Write(output, code, prefix, suffix, length);
                    next++;
                    previous = code;
                    if (next + early >= 1 << bits && bits < 12) bits++;
                    continue;
                }
                else
                {
                    return output.ToArray();
                }
                if (next < TableSize)
                {
                    Entry(next, previous, head, prefix, suffix, first, length);
                    next++;
                    if (next + early >= 1 << bits && bits < 12) bits++;
                }
                previous = code;
            }
        }
        return output.ToArray();
    }

    private static void Entry(int index, int previous, byte head, int[] prefix, byte[] suffix, byte[] first, int[] length)
    {
        prefix[index] = previous;
        suffix[index] = head;
        first[index] = first[previous];
        length[index] = length[previous] + 1;
    }

    private static void Write(FilterBuffer output, int code, int[] prefix, byte[] suffix, int[] length)
    {
        var span = output.Append(length[code]);
        for (int i = span.Length - 1; i >= 0; i--)
        {
            span[i] = suffix[code];
            code = prefix[code];
        }
    }

    public static byte[] Encode(ReadOnlySpan<byte> data, bool earlyChange)
    {
        var output = new FilterBuffer(Array.MaxLength, data.Length / 2);
        var table = new Dictionary<int, int>();
        int early = earlyChange ? 1 : 0;
        int bits = 9, next = First;
        uint pending = 0;
        int pendingBits = 0;

        void Put(int code)
        {
            pending = pending << bits | (uint)code;
            pendingBits += bits;
            while (pendingBits >= 8)
            {
                pendingBits -= 8;
                output.Add((byte)(pending >> pendingBits));
            }
            pending &= (1u << pendingBits) - 1;
        }

        // The encoder's table runs one entry ahead of the decoder's, hence the minus one.
        void Grow()
        {
            next++;
            if (next + early - 1 >= 1 << bits && bits < 12) bits++;
        }

        Put(Clear);
        int current = -1;
        foreach (byte b in data)
        {
            if (current < 0)
            {
                current = b;
                continue;
            }
            int key = current << 8 | b;
            if (table.TryGetValue(key, out int found))
            {
                current = found;
                continue;
            }
            Put(current);
            table[key] = next;
            Grow();
            if (next >= TableSize - 2)
            {
                Put(Clear);
                table.Clear();
                next = First;
                bits = 9;
            }
            current = b;
        }
        if (current >= 0)
        {
            Put(current);
            Grow();
        }
        Put(End);
        if (pendingBits > 0) output.Add((byte)(pending << (8 - pendingBits)));
        return output.ToArray();
    }
}
