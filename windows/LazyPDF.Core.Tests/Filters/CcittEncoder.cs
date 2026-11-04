namespace LazyPDF.Core.Tests;

// From Lazy Scan's CcittG4Encoder.cs, with Group 3 rows added. A second, independent way to make CCITT data
// for the decoder tests.

/// <summary>
/// CCITT Group 4 (ITU-T T.6) encoding of a black &amp; white image: the two-dimensional coding
/// of each row against the row above it (an imaginary white row above the first), with pass,
/// horizontal and vertical modes, ending in EOFB and zero bits up to a byte boundary. No EOLs,
/// no byte alignment of rows, bits written most significant first (TIFF FillOrder 1). Rows are
/// coded as libtiff codes them, mode for mode, so the output equals libtiff's for the same image.
/// The data goes into a PDF as /CCITTFaxDecode with /K -1 and into a TIFF as compression 4.
/// </summary>
internal static class CcittEncoder
{
    /// <summary>
    /// The image (packed rows, (width + 7) / 8 bytes each, most
    /// significant bit first, 0 = black) as G4 data.
    /// </summary>
    public static byte[] Encode(ReadOnlySpan<byte> packed, int width, int height)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(width, 1);
        ArgumentOutOfRangeException.ThrowIfNegative(height);
        int stride = (width + 7) / 8;
        if (packed.Length < (long)stride * height)
            throw new ArgumentException($"Packed buffer must be {(long)stride * height} bytes, got {packed.Length}.", nameof(packed));

        var bits = new BitWriter(Math.Max(64, stride * height / 8));
        // The changing elements of the reference row and the coding row: each position where a
        // pixel's color differs from the pixel before it (white before the first). Even entries
        // start black runs, odd entries white ones.
        var reference = new int[width + 1];
        var coding = new int[width + 1];
        int referenceCount = 0;
        for (int y = 0; y < height; y++)
        {
            int codingCount = ChangingElements(packed.Slice(y * stride, stride), width, coding);
            EncodeRow(ref bits, coding, codingCount, reference, referenceCount, width);
            (reference, coding) = (coding, reference);
            referenceCount = codingCount;
        }
        // EOFB: two EOLs.
        bits.Write(0x001, 12);
        bits.Write(0x001, 12);
        return bits.ToArray();
    }

    /// <summary>
    /// Group 3: K 0 codes every row alone, K above 0 codes a row alone, then K - 1 rows against the
    /// one above. With <paramref name="eol"/> an EOL (and for K above 0 the tag bit) goes before each
    /// row and six at the end; with <paramref name="align"/> rows (or the EOLs, which end on a byte) are byte aligned.
    /// </summary>
    public static byte[] EncodeG3(ReadOnlySpan<byte> packed, int width, int height, int k, bool eol, bool align)
    {
        int stride = (width + 7) / 8;
        var bits = new BitWriter(64);
        var reference = new int[width + 1];
        var coding = new int[width + 1];
        int referenceCount = 0;
        for (int y = 0; y < height; y++)
        {
            bool oneD = k == 0 || y % k == 0;
            if (eol)
            {
                if (align) bits.PadTo(k > 0 ? 13 : 12);
                bits.Write(0x001, 12);
                if (k > 0) bits.Write(oneD ? 1 : 0, 1);
            }
            else if (align)
            {
                bits.PadTo(0);
            }
            int codingCount = ChangingElements(packed.Slice(y * stride, stride), width, coding);
            if (oneD)
            {
                int position = 0;
                bool black = false;
                for (int i = 0; i < codingCount; i++)
                {
                    WriteRun(ref bits, coding[i] - position, black);
                    position = coding[i];
                    black = !black;
                }
                WriteRun(ref bits, width - position, black);
            }
            else
            {
                EncodeRow(ref bits, coding, codingCount, reference, referenceCount, width);
            }
            (reference, coding) = (coding, reference);
            referenceCount = codingCount;
        }
        if (eol)
        {
            for (int i = 0; i < 6; i++)
            {
                bits.Write(0x001, 12);
                if (k > 0) bits.Write(1, 1);
            }
        }
        return bits.ToArray();
    }


    /// <summary>Fills <paramref name="changes"/> with the row's changing elements; returns how many.</summary>
    private static int ChangingElements(ReadOnlySpan<byte> row, int width, int[] changes)
    {
        int count = 0;
        bool black = false;
        for (int x = 0; x < width; x++)
        {
            bool pixel = (row[x >> 3] & (0x80 >> (x & 7))) == 0;
            if (pixel != black)
            {
                changes[count++] = x;
                black = pixel;
            }
        }
        return count;
    }

    /// <summary>
    /// One row in T.6's two-dimensional coding. a0 starts on an imaginary white pixel before the
    /// row; a1 and a2 are the next changing elements of the coding row, b1 the first changing
    /// element of the reference row right of a0 and of the color opposite a0's, b2 the next one.
    /// </summary>
    private static void EncodeRow(ref BitWriter bits, int[] coding, int codingCount,
                                  int[] reference, int referenceCount, int width)
    {
        int a0 = -1;
        bool black = false; // the color of a0
        int ia = 0, ib = 0;
        while (true)
        {
            while (ia < codingCount && coding[ia] <= a0) ia++;
            int a1 = ia < codingCount ? coding[ia] : width;

            // Changing elements alternate in color, so b1 is the first one right of a0 or the
            // one after it. Only those at or left of a0 are skipped for good: one of the wrong
            // color can be b1 again once a vertical mode has changed a0's color.
            while (ib < referenceCount && reference[ib] <= a0) ib++;
            int k = ib;
            // Even entries are black; b1 has the color opposite a0's.
            if (k < referenceCount && (k % 2 == 0) == black) k++;
            int b1 = k < referenceCount ? reference[k] : width;
            int b2 = k + 1 < referenceCount ? reference[k + 1] : width;

            if (b2 < a1)
            {
                // Pass mode: a0 moves under b2 and keeps its color.
                bits.Write(PassCode, PassLength);
                a0 = b2;
            }
            else if (Math.Abs(a1 - b1) <= 3)
            {
                // Vertical mode: a1 is coded by its distance from b1.
                var (code, length) = Vertical[a1 - b1 + 3];
                bits.Write(code, length);
                a0 = a1;
                black = !black;
            }
            else
            {
                // Horizontal mode: the run from a0 to a1 in a0's color, then a1 to a2 in the other.
                int a2 = ia + 1 < codingCount ? coding[ia + 1] : width;
                int start = Math.Max(a0, 0);
                bits.Write(HorizontalCode, HorizontalLength);
                WriteRun(ref bits, a1 - start, black);
                WriteRun(ref bits, a2 - a1, !black);
                a0 = a2;
            }
            if (a0 >= width) return;
        }
    }

    /// <summary>
    /// One run as Modified Huffman codes: 2560 extended make-up codes while 2624 or more remain,
    /// then one make-up code for a remaining multiple of 64, then the terminating code (as libtiff).
    /// </summary>
    private static void WriteRun(ref BitWriter bits, int run, bool black)
    {
        var terminating = black ? BlackTerminating : WhiteTerminating;
        var makeUp = black ? BlackMakeUp : WhiteMakeUp;
        while (run >= 2624)
        {
            bits.Write(ExtendedMakeUp[^1].Code, ExtendedMakeUp[^1].Length);
            run -= 2560;
        }
        if (run >= 64)
        {
            int index = run / 64 - 1; // 64 → 0 ... 2560 → 39
            var (code, length) = index < makeUp.Length ? makeUp[index] : ExtendedMakeUp[index - makeUp.Length];
            bits.Write(code, length);
            run -= (index + 1) * 64;
        }
        bits.Write(terminating[run].Code, terminating[run].Length);
    }

    // MARK: - Code tables

    private const int PassCode = 0b0001, PassLength = 4;
    private const int HorizontalCode = 0b001, HorizontalLength = 3;

    /// <summary>Vertical mode codes by a1 − b1 + 3: VL3, VL2, VL1, V0, VR1, VR2, VR3.</summary>
    private static readonly (int Code, int Length)[] Vertical =
        Codes(["0000010", "000010", "010", "1", "011", "000011", "0000011"]);

    /// <summary>White terminating codes, runs 0–63 (T.4 table 2).</summary>
    private static readonly (int Code, int Length)[] WhiteTerminating = Codes(
    [
        "00110101", "000111", "0111", "1000", "1011", "1100", "1110", "1111",
        "10011", "10100", "00111", "01000", "001000", "000011", "110100", "110101",
        "101010", "101011", "0100111", "0001100", "0001000", "0010111", "0000011", "0000100",
        "0101000", "0101011", "0010011", "0100100", "0011000", "00000010", "00000011", "00011010",
        "00011011", "00010010", "00010011", "00010100", "00010101", "00010110", "00010111", "00101000",
        "00101001", "00101010", "00101011", "00101100", "00101101", "00000100", "00000101", "00001010",
        "00001011", "01010010", "01010011", "01010100", "01010101", "00100100", "00100101", "01011000",
        "01011001", "01011010", "01011011", "01001010", "01001011", "00110010", "00110011", "00110100",
    ]);

    /// <summary>Black terminating codes, runs 0–63 (T.4 table 2).</summary>
    private static readonly (int Code, int Length)[] BlackTerminating = Codes(
    [
        "0000110111", "010", "11", "10", "011", "0011", "0010", "00011",
        "000101", "000100", "0000100", "0000101", "0000111", "00000100", "00000111", "000011000",
        "0000010111", "0000011000", "0000001000", "00001100111", "00001101000", "00001101100", "00000110111", "00000101000",
        "00000010111", "00000011000", "000011001010", "000011001011", "000011001100", "000011001101", "000001101000", "000001101001",
        "000001101010", "000001101011", "000011010010", "000011010011", "000011010100", "000011010101", "000011010110", "000011010111",
        "000001101100", "000001101101", "000011011010", "000011011011", "000001010100", "000001010101", "000001010110", "000001010111",
        "000001100100", "000001100101", "000001010010", "000001010011", "000000100100", "000000110111", "000000111000", "000000100111",
        "000000101000", "000001011000", "000001011001", "000000101011", "000000101100", "000001011010", "000001100110", "000001100111",
    ]);

    /// <summary>White make-up codes, runs 64–1728 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] WhiteMakeUp = Codes(
    [
        "11011", "10010", "010111", "0110111", "00110110", "00110111", "01100100", "01100101",
        "01101000", "01100111", "011001100", "011001101", "011010010", "011010011", "011010100", "011010101",
        "011010110", "011010111", "011011000", "011011001", "011011010", "011011011", "010011000", "010011001",
        "010011010", "011000", "010011011",
    ]);

    /// <summary>Black make-up codes, runs 64–1728 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] BlackMakeUp = Codes(
    [
        "0000001111", "000011001000", "000011001001", "000001011011", "000000110011", "000000110100", "000000110101", "0000001101100",
        "0000001101101", "0000001001010", "0000001001011", "0000001001100", "0000001001101", "0000001110010", "0000001110011", "0000001110100",
        "0000001110101", "0000001110110", "0000001110111", "0000001010010", "0000001010011", "0000001010100", "0000001010101", "0000001011010",
        "0000001011011", "0000001100100", "0000001100101",
    ]);

    /// <summary>Extended make-up codes for both colors, runs 1792–2560 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] ExtendedMakeUp = Codes(
    [
        "00000001000", "00000001100", "00000001101", "000000010010", "000000010011", "000000010100", "000000010101",
        "000000010110", "000000010111", "000000011100", "000000011101", "000000011110", "000000011111",
    ]);

    private static (int Code, int Length)[] Codes(string[] bitStrings) =>
        bitStrings.Select(s => (Convert.ToInt32(s, 2), s.Length)).ToArray();

    // MARK: - Bits

    /// <summary>Bits most significant first; the last byte is filled up with zero bits.</summary>
    private struct BitWriter(int capacity)
    {
        private byte[] _bytes = new byte[capacity];
        private int _count;
        private uint _pending;
        private int _pendingBits;

        public void Write(int code, int length)
        {
            // length ≤ 13, and fewer than 8 bits wait: at most 20 bits are held.
            _pending = (_pending << length) | ((uint)code & ((1u << length) - 1));
            _pendingBits += length;
            while (_pendingBits >= 8)
            {
                _pendingBits -= 8;
                Append((byte)(_pending >> _pendingBits));
            }
            _pending &= (1u << _pendingBits) - 1;
        }

        /// <summary>Zero bits until the bits written plus <paramref name="following"/> more end on a byte boundary.</summary>
        public void PadTo(int following)
        {
            while ((_count * 8 + _pendingBits + following) % 8 != 0) Write(0, 1);
        }

        public byte[] ToArray()
        {
            if (_pendingBits > 0)
            {
                Append((byte)(_pending << (8 - _pendingBits)));
                _pending = 0;
                _pendingBits = 0;
            }
            return _bytes.AsSpan(0, _count).ToArray();
        }

        private void Append(byte value)
        {
            if (_count == _bytes.Length) Array.Resize(ref _bytes, _bytes.Length * 2);
            _bytes[_count++] = value;
        }
    }
}
