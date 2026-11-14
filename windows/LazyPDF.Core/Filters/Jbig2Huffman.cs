/* Copyright 2012 Mozilla Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Ported to C# from pdf.js (src/core/jbig2.js: Reader, HuffmanTable, decodeTablesSegment, getStandardTable) and
// changed: codes are assigned by B.3 for the standard tables too and decoded by length instead of through a
// tree, and prefix lengths, range lengths and line counts are checked.

namespace LazyPDF.Core;

/// <summary>Bits of a segment's data, most significant first; reading past its end is damage.</summary>
internal sealed class Jbig2Reader(byte[] data, int start, int end)
{
    private int _shift = -1;
    private int _current;

    public byte[] Data { get; } = data;

    /// <summary>The next byte to start on; with a byte only partly read it is the one after it.</summary>
    public int Position { get; set; } = start;

    public int End { get; set; } = Math.Min(end, data.Length);

    public int ReadBit()
    {
        if (_shift < 0)
        {
            if (Position >= End) throw PdfReadException.Damaged("A JBIG2 segment ends in the middle of its data.");
            _current = Data[Position++];
            _shift = 7;
        }
        return (_current >> _shift--) & 1;
    }

    /// <summary>Up to 32 bits as one number.</summary>
    public long ReadBits(int count)
    {
        long result = 0;
        for (int i = 0; i < count; i++) result = (result << 1) | (uint)ReadBit();
        return result;
    }

    public void ByteAlign() => _shift = -1;
}

/// <summary>A prefix code table (Annex B) of values with a range of offset bits each, and maybe an out-of-band value.</summary>
internal sealed class Jbig2Huffman
{
    private const int Normal = 0, Lower = 1, OutOfBand = 3;

    private const int MaxPrefixLength = 32;

    private const int MaxCustomLines = 1 << 12;

    private readonly long[] _low;
    private readonly int[] _rangeLength;
    private readonly int[] _kind;
    private readonly int[] _byLength;
    private readonly long[] _first;
    private readonly int[] _count;
    private readonly int[] _start;
    private readonly int _longest;

    /// <summary>The prefix code B.3 gives each line, for tests.</summary>
    internal long[] Codes { get; }

    /// <summary>Lines of (range low, prefix length, range length, kind); a line with prefix length 0 is not used.</summary>
    public Jbig2Huffman((long Low, int PrefixLength, int RangeLength, int Kind)[] lines)
    {
        int n = lines.Length;
        _low = new long[n];
        _rangeLength = new int[n];
        _kind = new int[n];
        var counts = new int[MaxPrefixLength + 1];
        for (int i = 0; i < n; i++)
        {
            if (lines[i].PrefixLength is < 0 or > MaxPrefixLength || lines[i].RangeLength is < 0 or > 32)
                throw PdfReadException.Damaged("A JBIG2 Huffman table has a code length out of range.");
            _low[i] = lines[i].Low;
            _rangeLength[i] = lines[i].RangeLength;
            _kind[i] = lines[i].Kind;
            counts[lines[i].PrefixLength]++;
            _longest = Math.Max(_longest, lines[i].PrefixLength);
        }
        counts[0] = 0;
        _count = counts;
        _first = new long[MaxPrefixLength + 1];
        _start = new int[MaxPrefixLength + 1];
        // B.3: codes of one length are consecutive, in the order of the lines.
        long first = 0;
        int at = 0;
        for (int length = 1; length <= _longest; length++)
        {
            first = (first + counts[length - 1]) << 1;
            if (first + counts[length] > 1L << length) throw PdfReadException.Damaged("A JBIG2 Huffman table has more codes than fit.");
            _first[length] = first;
            _start[length] = at;
            at += counts[length];
        }
        _byLength = new int[at];
        Codes = new long[n];
        var next = new int[MaxPrefixLength + 1];
        for (int i = 0; i < n; i++)
        {
            int length = lines[i].PrefixLength;
            if (length == 0) continue;
            _byLength[_start[length] + next[length]] = i;
            Codes[i] = _first[length] + next[length]++;
        }
    }

    /// <summary>A value, or false for the out-of-band value.</summary>
    public bool Decode(Jbig2Reader reader, out int value)
    {
        long code = 0;
        for (int length = 1; length <= _longest; length++)
        {
            code = (code << 1) | (uint)reader.ReadBit();
            long index = code - _first[length];
            if (index < 0 || index >= _count[length]) continue;
            int line = _byLength[_start[length] + (int)index];
            value = 0;
            if (_kind[line] == OutOfBand) return false;
            long offset = reader.ReadBits(_rangeLength[line]);
            long result = _kind[line] == Lower ? _low[line] - offset : _low[line] + offset;
            if (result < int.MinValue || result > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 Huffman value is out of range.");
            value = (int)result;
            return true;
        }
        throw PdfReadException.Damaged("A JBIG2 Huffman code is not in its table.");
    }

    /// <summary>B.2: the table a tables segment holds.</summary>
    public static Jbig2Huffman Custom(byte[] data, int start, int end)
    {
        if (end - start < 9) throw PdfReadException.Damaged("A JBIG2 tables segment is cut off.");
        int flags = data[start];
        long lowest = (int)(((uint)data[start + 1] << 24) | ((uint)data[start + 2] << 16) | ((uint)data[start + 3] << 8) | data[start + 4]);
        long highest = (int)(((uint)data[start + 5] << 24) | ((uint)data[start + 6] << 16) | ((uint)data[start + 7] << 8) | data[start + 8]);
        var reader = new Jbig2Reader(data, start + 9, end);
        int prefixBits = ((flags >> 1) & 7) + 1;
        int rangeBits = ((flags >> 4) & 7) + 1;
        var lines = new List<(long, int, int, int)>();
        long current = lowest;
        do
        {
            int prefix = (int)reader.ReadBits(prefixBits);
            int range = (int)reader.ReadBits(rangeBits);
            if (range > 32) throw PdfReadException.Damaged("A JBIG2 Huffman table has a range out of range.");
            lines.Add((current, prefix, range, Normal));
            if (lines.Count > MaxCustomLines) throw Jbig2Budget.TooBig();
            current += 1L << range;
        } while (current < highest);
        lines.Add((lowest - 1, (int)reader.ReadBits(prefixBits), 32, Lower));
        lines.Add((highest, (int)reader.ReadBits(prefixBits), 32, Normal));
        if ((flags & 1) != 0) lines.Add((0, (int)reader.ReadBits(prefixBits), 0, OutOfBand));
        return new Jbig2Huffman([.. lines]);
    }

    /// <summary>The table of the symbol ids of a text region (7.4.3.1.7): symbol i has a code of <paramref name="lengths"/>[i] bits.</summary>
    public static Jbig2Huffman ForLengths(int[] lengths)
    {
        var lines = new (long, int, int, int)[lengths.Length];
        for (int i = 0; i < lengths.Length; i++) lines[i] = (i, lengths[i], 0, Normal);
        return new Jbig2Huffman(lines);
    }

    private static readonly Jbig2Huffman?[] StandardTables = new Jbig2Huffman?[16];

    /// <summary>Table B.<paramref name="number"/>, 1 to 15.</summary>
    public static Jbig2Huffman Standard(int number) =>
        StandardTables[number] ??= new Jbig2Huffman(StandardLines[number - 1]);

    /// <summary>The lines of a standard table, for tests.</summary>
    internal static (long Low, int PrefixLength, int RangeLength, int Kind)[] StandardTable(int number) => StandardLines[number - 1];

    // Annex B.5: (range low, prefix length, range length, kind) for each line in the order of the standard, with the
    // lower range line as kind 1 and the out-of-band line as kind 3. The last range of a table has 32 offset bits.
    private static readonly (long Low, int PrefixLength, int RangeLength, int Kind)[][] StandardLines =
    [
        // B.1
        [
            (0, 1, 4, 0), (16, 2, 8, 0), (272, 3, 16, 0), (65808, 3, 32, 0),
        ],
        // B.2
        [
            (0, 1, 0, 0), (1, 2, 0, 0), (2, 3, 0, 0), (3, 4, 3, 0), (11, 5, 6, 0), (75, 6, 32, 0), (0, 6, 0, 3),
        ],
        // B.3
        [
            (-256, 8, 8, 0), (0, 1, 0, 0), (1, 2, 0, 0), (2, 3, 0, 0), (3, 4, 3, 0), (11, 5, 6, 0), (-257, 8, 32, 1),
            (75, 7, 32, 0), (0, 6, 0, 3),
        ],
        // B.4
        [
            (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 0, 0), (4, 4, 3, 0), (12, 5, 6, 0), (76, 5, 32, 0),
        ],
        // B.5
        [
            (-255, 7, 8, 0), (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 0, 0), (4, 4, 3, 0), (12, 5, 6, 0), (-256, 7, 32, 1),
            (76, 6, 32, 0),
        ],
        // B.6
        [
            (-2048, 5, 10, 0), (-1024, 4, 9, 0), (-512, 4, 8, 0), (-256, 4, 7, 0), (-128, 5, 6, 0), (-64, 5, 5, 0),
            (-32, 4, 5, 0), (0, 2, 7, 0), (128, 3, 7, 0), (256, 3, 8, 0), (512, 4, 9, 0), (1024, 4, 10, 0),
            (-2049, 6, 32, 1), (2048, 6, 32, 0),
        ],
        // B.7
        [
            (-1024, 4, 9, 0), (-512, 3, 8, 0), (-256, 4, 7, 0), (-128, 5, 6, 0), (-64, 5, 5, 0), (-32, 4, 5, 0),
            (0, 4, 5, 0), (32, 5, 5, 0), (64, 5, 6, 0), (128, 4, 7, 0), (256, 3, 8, 0), (512, 3, 9, 0),
            (1024, 3, 10, 0), (-1025, 5, 32, 1), (2048, 5, 32, 0),
        ],
        // B.8
        [
            (-15, 8, 3, 0), (-7, 9, 1, 0), (-5, 8, 1, 0), (-3, 9, 0, 0), (-2, 7, 0, 0), (-1, 4, 0, 0), (0, 2, 1, 0),
            (2, 5, 0, 0), (3, 6, 0, 0), (4, 3, 4, 0), (20, 6, 1, 0), (22, 4, 4, 0), (38, 4, 5, 0), (70, 5, 6, 0),
            (134, 5, 7, 0), (262, 6, 7, 0), (390, 7, 8, 0), (646, 6, 10, 0), (-16, 9, 32, 1), (1670, 9, 32, 0),
            (0, 2, 0, 3),
        ],
        // B.9
        [
            (-31, 8, 4, 0), (-15, 9, 2, 0), (-11, 8, 2, 0), (-7, 9, 1, 0), (-5, 7, 1, 0), (-3, 4, 1, 0),
            (-1, 3, 1, 0), (1, 3, 1, 0), (3, 5, 1, 0), (5, 6, 1, 0), (7, 3, 5, 0), (39, 6, 2, 0), (43, 4, 5, 0),
            (75, 4, 6, 0), (139, 5, 7, 0), (267, 5, 8, 0), (523, 6, 8, 0), (779, 7, 9, 0), (1291, 6, 11, 0),
            (-32, 9, 32, 1), (3339, 9, 32, 0), (0, 2, 0, 3),
        ],
        // B.10
        [
            (-21, 7, 4, 0), (-5, 8, 0, 0), (-4, 7, 0, 0), (-3, 5, 0, 0), (-2, 2, 2, 0), (2, 5, 0, 0), (3, 6, 0, 0),
            (4, 7, 0, 0), (5, 8, 0, 0), (6, 2, 6, 0), (70, 5, 5, 0), (102, 6, 5, 0), (134, 6, 6, 0), (198, 6, 7, 0),
            (326, 6, 8, 0), (582, 6, 9, 0), (1094, 6, 10, 0), (2118, 7, 11, 0), (-22, 8, 32, 1), (4166, 8, 32, 0),
            (0, 2, 0, 3),
        ],
        // B.11
        [
            (1, 1, 0, 0), (2, 2, 1, 0), (4, 4, 0, 0), (5, 4, 1, 0), (7, 5, 1, 0), (9, 5, 2, 0), (13, 6, 2, 0),
            (17, 7, 2, 0), (21, 7, 3, 0), (29, 7, 4, 0), (45, 7, 5, 0), (77, 7, 6, 0), (141, 7, 32, 0),
        ],
        // B.12
        [
            (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 1, 0), (5, 5, 0, 0), (6, 5, 1, 0), (8, 6, 1, 0), (10, 7, 0, 0),
            (11, 7, 1, 0), (13, 7, 2, 0), (17, 7, 3, 0), (25, 7, 4, 0), (41, 8, 5, 0), (73, 8, 32, 0),
        ],
        // B.13
        [
            (1, 1, 0, 0), (2, 3, 0, 0), (3, 4, 0, 0), (4, 5, 0, 0), (5, 4, 1, 0), (7, 3, 3, 0), (15, 6, 1, 0),
            (17, 6, 2, 0), (21, 6, 3, 0), (29, 6, 4, 0), (45, 6, 5, 0), (77, 7, 6, 0), (141, 7, 32, 0),
        ],
        // B.14
        [
            (-2, 3, 0, 0), (-1, 3, 0, 0), (0, 1, 0, 0), (1, 3, 0, 0), (2, 3, 0, 0),
        ],
        // B.15
        [
            (-24, 7, 4, 0), (-8, 6, 2, 0), (-4, 5, 1, 0), (-2, 4, 0, 0), (-1, 3, 0, 0), (0, 1, 0, 0), (1, 3, 0, 0),
            (2, 4, 0, 0), (3, 5, 1, 0), (5, 6, 2, 0), (9, 7, 4, 0), (-25, 7, 32, 1), (25, 7, 32, 0),
        ],    ];
}
