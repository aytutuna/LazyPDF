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

// Ported to C# from pdf.js (src/core/arithmetic_decoder.js and the integer procedures of src/core/jbig2.js)
// and changed: the contexts are plain byte arrays kept with the decoder, bytes past the end of the data read
// as 0xFF, and every value is range checked.

namespace LazyPDF.Core;

/// <summary>
/// The MQ arithmetic decoder of T.88 Annex E (the QM coder of JPEG 2000 Annex C) with the context
/// sets one segment needs: the generic and refinement region contexts and the integer procedures of Annex A.
/// A context is one byte, the state index in the upper seven bits and the more probable symbol in bit 0.
/// </summary>
internal sealed class Jbig2Arith
{
    private static readonly int[] Qe =
    [
        0x5601, 0x3401, 0x1801, 0x0ac1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1c01, 0x1601, 0x5601,
        0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1c01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101,
        0x0ac1, 0x09c1, 0x08a1, 0x0521, 0x0441, 0x02a1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025, 0x0015, 0x0009, 0x0005,
        0x0001, 0x5601,
    ];

    private static readonly byte[] Nmps =
    [
        1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
    ];

    private static readonly byte[] Nlps =
    [
        1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
    ];

    // The states where the less probable symbol swaps with the more probable one.
    private static readonly bool[] Switch = MakeSwitch();

    private static bool[] MakeSwitch()
    {
        var table = new bool[47];
        table[0] = table[6] = table[14] = true;
        return table;
    }

    public const int Iadh = 0, Iadw = 1, Iaex = 2, Iaai = 3, Iadt = 4, Iafs = 5, Iads = 6, Iait = 7, Iari = 8, Iardw = 9, Iardh = 10, Iardx = 11, Iardy = 12;
    private const int IntegerCount = 13;

    private readonly byte[] _data;
    private readonly int _end;
    private int _bp;
    private int _chigh;
    private int _clow;
    private int _a;
    private int _ct;
    private byte[]? _iaid;
    private readonly byte[]?[] _integers = new byte[IntegerCount][];

    /// <summary>Generic region contexts (the largest template has 16 bits).</summary>
    public byte[] Gb;

    /// <summary>Generic refinement region contexts (the largest template has 13 bits).</summary>
    public byte[] Gr;

    /// <summary>E.3.5 INITDEC: starts decoding the bytes from <paramref name="start"/> up to <paramref name="end"/>.</summary>
    public Jbig2Arith(byte[] data, int start, int end, byte[]? refinementContexts = null, Jbig2Budget? budget = null)
    {
        budget?.Fixed(refinementContexts is null ? 80_000 : 0);
        // A decoder that only refines (Huffman coded blocks, one for each symbol) has no use for the other contexts.
        Gb = refinementContexts is null ? new byte[1 << 16] : [];
        Gr = refinementContexts ?? new byte[1 << 13];
        _data = data;
        _end = Math.Min(end, data.Length);
        _bp = start;
        _chigh = At(start);
        _clow = 0;
        ByteIn();
        _chigh = ((_chigh << 7) & 0xffff) | ((_clow >> 9) & 0x7f);
        _clow = (_clow << 7) & 0xffff;
        _ct -= 7;
        _a = 0x8000;
    }

    private int At(int index) => index >= 0 && index < _end ? _data[index] : 0xff;

    // E.3.4 BYTEIN
    private void ByteIn()
    {
        if (At(_bp) == 0xff)
        {
            if (At(_bp + 1) > 0x8f)
            {
                _clow += 0xff00;
                _ct = 8;
            }
            else
            {
                _bp++;
                _clow += At(_bp) << 9;
                _ct = 7;
            }
        }
        else
        {
            _bp++;
            _clow += _bp < _end ? _data[_bp] << 8 : 0xff00;
            _ct = 8;
        }
        if (_clow > 0xffff)
        {
            _chigh += _clow >> 16;
            _clow &= 0xffff;
        }
    }

    /// <summary>E.3.2 DECODE: one bit under the context at <paramref name="pos"/> of <paramref name="contexts"/>.</summary>
    public int Bit(byte[] contexts, int pos)
    {
        int index = contexts[pos] >> 1;
        int mps = contexts[pos] & 1;
        int qe = Qe[index];
        int d;
        int a = _a - qe;

        if (_chigh < qe)
        {
            if (a < qe)
            {
                a = qe;
                d = mps;
                index = Nmps[index];
            }
            else
            {
                a = qe;
                d = 1 ^ mps;
                if (Switch[index]) mps = d;
                index = Nlps[index];
            }
        }
        else
        {
            _chigh -= qe;
            if ((a & 0x8000) != 0)
            {
                _a = a;
                return mps;
            }
            if (a < qe)
            {
                d = 1 ^ mps;
                if (Switch[index]) mps = d;
                index = Nlps[index];
            }
            else
            {
                d = mps;
                index = Nmps[index];
            }
        }
        // E.3.3 RENORMD
        do
        {
            if (_ct == 0) ByteIn();
            a <<= 1;
            _chigh = ((_chigh << 1) & 0xffff) | ((_clow >> 15) & 1);
            _clow = (_clow << 1) & 0xffff;
            _ct--;
        } while ((a & 0x8000) == 0);
        _a = a;
        contexts[pos] = (byte)((index << 1) | mps);
        return d;
    }

    /// <summary>
    /// A.2: one integer of the procedure whose contexts are <paramref name="procedure"/> (<see cref="Iadh"/> and so on).
    /// False for the out-of-band value.
    /// </summary>
    public bool Integer(int procedure, out int value)
    {
        var contexts = _integers[procedure] ??= new byte[512];
        int prev = 1;
        int sign = (int)ReadBits(contexts, ref prev, 1);
        long v;
        if (ReadBits(contexts, ref prev, 1) == 0) v = ReadBits(contexts, ref prev, 2);
        else if (ReadBits(contexts, ref prev, 1) == 0) v = ReadBits(contexts, ref prev, 4) + 4;
        else if (ReadBits(contexts, ref prev, 1) == 0) v = ReadBits(contexts, ref prev, 6) + 20;
        else if (ReadBits(contexts, ref prev, 1) == 0) v = ReadBits(contexts, ref prev, 8) + 84;
        else if (ReadBits(contexts, ref prev, 1) == 0) v = ReadBits(contexts, ref prev, 12) + 340;
        else v = ReadBits(contexts, ref prev, 32) + 4436;
        value = 0;
        if (sign != 0 && v == 0) return false;
        if (sign != 0) v = -v;
        if (v < int.MinValue || v > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 integer is out of range.");
        value = (int)v;
        return true;
    }

    private long ReadBits(byte[] contexts, ref int prev, int length)
    {
        long v = 0;
        for (int i = 0; i < length; i++)
        {
            int bit = Bit(contexts, prev);
            prev = prev < 256 ? (prev << 1) | bit : (((prev << 1) | bit) & 511) | 256;
            v = (v << 1) | (uint)bit;
        }
        return v;
    }

    /// <summary>A.3: a symbol id of <paramref name="codeLength"/> bits.</summary>
    public int Iaid(int codeLength)
    {
        if (_iaid is null || _iaid.Length < 1 << (codeLength + 1)) _iaid = new byte[1 << (codeLength + 1)];
        int prev = 1;
        for (int i = 0; i < codeLength; i++) prev = (prev << 1) | Bit(_iaid, prev);
        return prev & ((1 << codeLength) - 1);
    }
}
