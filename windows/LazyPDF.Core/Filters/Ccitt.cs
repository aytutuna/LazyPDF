namespace LazyPDF.Core;

/// <summary>
/// CCITTFaxDecode (ISO 32000-1 7.4.6; ITU-T T.4 and T.6): K below zero is Group 4, zero is
/// Group 3 one-dimensional, above zero is Group 3 with a tag bit after each EOL choosing one or
/// two dimensions for the next row. EOLs are accepted whether or not /EndOfLine says they are there.
/// </summary>
internal static class Ccitt
{
    /// <summary>
    /// Rows of packed pixels, each starting on a byte boundary, white 1 unless <paramref name="blackIs1"/>.
    /// A bad code ends a Group 4 stream; Group 3 skips to the next EOL. With <paramref name="rows"/> known, missing rows are white.
    /// </summary>
    public static byte[] Decode(byte[] data, int k, int columns, int rows, bool byteAlign, bool endOfLine, bool blackIs1, long maxSize)
    {
        int stride = (columns + 7) / 8;
        if (rows > 0 && (long)rows * stride > maxSize) throw FilterBuffer.TooBig();
        var output = new FilterBuffer(maxSize, rows > 0 ? rows * stride : data.Length * 4);
        byte white = blackIs1 ? (byte)0 : (byte)0xFF;
        var rowBytes = new byte[stride];
        var reference = new int[columns + 2];
        var coding = new int[columns + 2];
        int referenceCount = 0, done = 0;
        var bits = new BitReader(data);
        bool resynced = false;

        while (rows == 0 || done < rows)
        {
            // With EOLs the fill bits that align the row sit in front of the EOL, which then ends on the boundary.
            bool aligned = byteAlign && !resynced;
            if (aligned && !endOfLine) bits.Align();
            resynced = false;
            int eols = 0, tag = -1;
            while (bits.TryEol())
            {
                eols++;
                if (k > 0) tag = bits.Read1();
            }
            if (eols == 0 && aligned && endOfLine) bits.Align();
            if (bits.AtEnd || eols >= 2 || (k < 0 && eols > 0)) break;

            bool twoD = k < 0 || (k > 0 && (tag >= 0 ? tag == 0 : done > 0));
            long start = bits.Position;
            int count = 0;
            bool ok = twoD
                ? DecodeRow2D(ref bits, reference, referenceCount, coding, ref count, columns)
                : DecodeRow1D(ref bits, coding, ref count, columns);
            // Padding bits after the last row are not a row.
            if (!ok && bits.Position == start && bits.RestIsZero()) break;

            Array.Fill(rowBytes, white);
            for (int i = 0; i < count; i += 2) FillBlack(rowBytes, coding[i], i + 1 < count ? coding[i + 1] : columns, blackIs1);
            output.Add(rowBytes);
            done++;
            (reference, coding) = (coding, reference);
            referenceCount = count;

            if (ok) continue;
            if (k < 0) break;
            bits.SkipToEol();
            resynced = true;
            // Nothing sound to predict the next row from.
            referenceCount = 0;
        }
        if (rows > done) output.Append((rows - done) * stride).Fill(white);
        return output.ToArray();
    }

    /// <summary>One-dimensional row: alternating white and black runs. The changing elements go to <paramref name="changes"/>.</summary>
    private static bool DecodeRow1D(ref BitReader bits, int[] changes, ref int count, int columns)
    {
        int position = 0;
        bool black = false;
        while (position < columns)
        {
            int run = ReadRun(ref bits, black, columns);
            if (run < 0 || count >= changes.Length - 1) return false;
            position = Math.Min(position + run, columns);
            if (position < columns) changes[count++] = position;
            black = !black;
        }
        return true;
    }

    /// <summary>
    /// Two-dimensional row (T.6): a0 is the last coded position, b1 the first changing element of
    /// the reference row right of a0 and of the colour opposite a0's, b2 the one after it.
    /// </summary>
    private static bool DecodeRow2D(ref BitReader bits, int[] reference, int referenceCount, int[] changes, ref int count, int columns)
    {
        int a0 = -1, ib = 0;
        bool black = false;
        while (a0 < columns)
        {
            while (ib < referenceCount && reference[ib] <= a0) ib++;
            int index = ib;
            if (index < referenceCount && (index % 2 == 0) == black) index++;
            int b1 = index < referenceCount ? reference[index] : columns;
            int b2 = index + 1 < referenceCount ? reference[index + 1] : columns;

            int mode = bits.Peek(7);
            int offset;
            if (mode >> 6 == 1) { bits.Skip(1); offset = 0; }
            else if (mode >> 4 == 0b011) { bits.Skip(3); offset = 1; }
            else if (mode >> 4 == 0b010) { bits.Skip(3); offset = -1; }
            else if (mode >> 4 == 0b001)
            {
                bits.Skip(3);
                int first = ReadRun(ref bits, black, columns);
                int second = first < 0 ? -1 : ReadRun(ref bits, !black, columns);
                if (second < 0 || count >= changes.Length - 2) return false;
                int a1 = Math.Min(Math.Max(a0, 0) + first, columns);
                int a2 = Math.Min(a1 + second, columns);
                if (a1 < columns) changes[count++] = a1;
                if (a2 < columns) changes[count++] = a2;
                a0 = a2;
                continue;
            }
            else if (mode >> 3 == 0b0001)
            {
                bits.Skip(4);
                a0 = b2;
                continue;
            }
            else if (mode >> 1 == 0b000011) { bits.Skip(6); offset = 2; }
            else if (mode >> 1 == 0b000010) { bits.Skip(6); offset = -2; }
            else if (mode == 0b0000011) { bits.Skip(7); offset = 3; }
            else if (mode == 0b0000010) { bits.Skip(7); offset = -3; }
            else return false;

            int a1v = b1 + offset;
            if (a1v > columns || a1v < Math.Max(a0, 0) || (a1v == a0 && a0 >= 0)) return false;
            if (a1v < columns)
            {
                if (count >= changes.Length - 2) return false;
                changes[count++] = a1v;
            }
            a0 = a1v;
            black = !black;
        }
        return true;
    }

    /// <summary>A run of one colour: make-up codes then a terminating code. -1 for a code that does not exist.</summary>
    private static int ReadRun(ref BitReader bits, bool black, int columns)
    {
        var table = black ? CcittCodes.Black : CcittCodes.White;
        int total = 0;
        while (true)
        {
            int entry = table[bits.Peek(13)];
            if (entry == 0) return -1;
            bits.Skip(entry & 15);
            int run = entry >> 4;
            total += run;
            if (run < 64) return total;
            if (total > columns) return -1;
        }
    }

    private static void FillBlack(byte[] row, int from, int to, bool blackIs1)
    {
        for (int x = from; x < to;)
        {
            if ((x & 7) == 0 && to - x >= 8)
            {
                row[x >> 3] = blackIs1 ? (byte)0xFF : (byte)0;
                x += 8;
                continue;
            }
            int bit = 0x80 >> (x & 7);
            if (blackIs1) row[x >> 3] |= (byte)bit; else row[x >> 3] &= (byte)~bit;
            x++;
        }
    }

    private struct BitReader(byte[] data)
    {
        private long _position;
        private readonly long _end = data.Length * 8L;

        public readonly long Position => _position;

        public readonly bool AtEnd => _position >= _end;

        public void Skip(int count) => _position += count;

        public void Align() => _position = (_position + 7) & ~7L;

        /// <summary>The next <paramref name="count"/> bits (24 at most); zeros past the end.</summary>
        public readonly int Peek(int count)
        {
            long index = _position >> 3;
            uint value = 0;
            for (int i = 0; i < 4; i++) value = value << 8 | (index + i < data.Length ? data[index + i] : (uint)0);
            return (int)((value >> (32 - (int)(_position & 7) - count)) & ((1u << count) - 1));
        }

        public int Read1()
        {
            int bit = Peek(1);
            _position++;
            return bit;
        }

        /// <summary>Takes an EOL: at least 11 zeros, fill bits included, then a one. Anything else is left alone.</summary>
        public bool TryEol()
        {
            long at = _position;
            while (at < _end && ((data[at >> 3] >> (7 - (int)(at & 7))) & 1) == 0) at++;
            if (at - _position < 11) return false;
            if (at >= _end)
            {
                _position = _end;
                return false;
            }
            _position = at + 1;
            return true;
        }

        public readonly bool RestIsZero()
        {
            for (long at = _position; at < _end; at++)
            {
                if (((data[at >> 3] >> (7 - (int)(at & 7))) & 1) != 0) return false;
            }
            return true;
        }

        /// <summary>Moves to the next EOL, or the end.</summary>
        public void SkipToEol()
        {
            while (!AtEnd && Peek(12) != 1) _position++;
        }
    }
}
