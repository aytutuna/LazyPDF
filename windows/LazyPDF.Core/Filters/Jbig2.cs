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

// Ported to C# from pdf.js (src/core/jbig2.js: segment headers, SimpleSegmentVisitor) and changed: the page
// is composed with every combination operator, a segment that fails does not stop the others, and every
// size and count is checked against the budget before anything is allocated.

namespace LazyPDF.Core;

/// <summary>
/// JBIG2Decode (ISO 32000-1 7.4.7; ITU-T T.88): the segments of an embedded stream, the globals first,
/// drawn into one page that comes out as packed rows with 0 for black, as an image stream expects.
/// </summary>
internal static class Jbig2
{
    /// <summary>
    /// Rows of packed pixels, each starting on a byte boundary, black 0 and white 1 (the filter inverts JBIG2's black 1).
    /// A segment that does not decode is left out; the stream is damaged only when none of its regions could be drawn.
    /// </summary>
    public static byte[] Decode(byte[] globals, byte[] data, long maxSize)
    {
        var decoder = new Jbig2Decoder(maxSize);
        decoder.Read(globals);
        decoder.Read(data);
        return decoder.Finish();
    }
}

internal sealed class Jbig2Decoder(long maxSize)
{
    private readonly Jbig2Budget _budget = new();
    private int _failed;
    private int _drawn;
    private PdfReadException? _firstError;

    // The page (7.4.8). With an unknown height the bitmap grows with the regions and stripes, and _rows is what is used.
    private Jbig2Bitmap? _page;
    private bool _heightKnown;
    private int _rows;
    private byte _defaultPixel;

    private readonly Dictionary<long, Jbig2Bitmap> _intermediate = [];

    private readonly record struct Segment(long Number, int Type, long[] Referred, long Length, int HeaderEnd, bool UnknownLength);

    private readonly record struct Region(int Width, int Height, int X, int Y, int Op);

    /// <summary>The segments of <paramref name="data"/> one after the other (7.2), through the end of file segment.</summary>
    public void Read(byte[] data)
    {
        int position = 0;
        while (position < data.Length)
        {
            Segment segment;
            try
            {
                segment = ReadHeader(data, position);
            }
            catch (PdfReadException e) when (e.Problem == PdfReadProblem.Damaged)
            {
                Fail(e);
                return;
            }
            int start = segment.HeaderEnd;
            int end = (int)Math.Min(start + segment.Length, data.Length);
            try
            {
                Process(segment, data, start, end);
            }
            catch (PdfReadException e) when (e.Problem == PdfReadProblem.Damaged)
            {
                Fail(e);
            }
            catch (Exception e) when (e is IndexOutOfRangeException or ArgumentException or OverflowException or InvalidOperationException)
            {
                Fail(PdfReadException.Damaged("A JBIG2 segment does not decode."));
            }
            if (segment.Type == 51) return;
            position = end;
        }
    }

    private void Fail(PdfReadException e)
    {
        _failed++;
        _firstError ??= e;
    }

    /// <summary>7.2: the segment header at <paramref name="start"/>.</summary>
    private static Segment ReadHeader(byte[] data, int start)
    {
        int position = start;
        long number = U32(data, position);
        int flags = U8(data, position + 4);
        int type = flags & 0x3f;
        bool wideAssociation = (flags & 0x40) != 0;
        int referredFlags = U8(data, position + 5);
        long count = referredFlags >> 5;
        position += 6;
        if (count == 7)
        {
            count = U32(data, position - 1) & 0x1fffffff;
            // The retention bits take one bit for the segment itself and one for each one it refers to.
            long retainBytes = (count + 8) / 8;
            position += 3 + (int)retainBytes;
        }
        else if (count > 4)
        {
            throw PdfReadException.Damaged("A JBIG2 segment header has bad referred-to flags.");
        }
        int numberSize = number <= 256 ? 1 : number <= 65536 ? 2 : 4;
        // Each referred segment needs bytes in the header, so the count is bounded by the data.
        if (count * numberSize > data.Length - position) throw PdfReadException.Damaged("A JBIG2 segment header is cut off.");
        var referred = new long[count];
        for (int i = 0; i < count; i++)
        {
            referred[i] = numberSize == 1 ? U8(data, position) : numberSize == 2 ? U16(data, position) : U32(data, position);
            position += numberSize;
        }
        position += wideAssociation ? 4 : 1;
        long length = U32(data, position);
        position += 4;
        bool unknown = length == 0xffffffffL;
        if (unknown)
        {
            // 7.2.7: only an immediate generic region may have an unknown length; it ends with a marker and the row count.
            if (type != 38) throw PdfReadException.Damaged("A JBIG2 segment has no length.");
            length = UnknownLength(data, position);
        }
        return new Segment(number, type, referred, length, position, unknown);
    }

    private static long UnknownLength(byte[] data, int start)
    {
        // The flags byte of the generic region follows its 17 byte region information.
        bool mmr = (U8(data, start + 17) & 1) != 0;
        byte first = mmr ? (byte)0x00 : (byte)0xff;
        byte second = mmr ? (byte)0x00 : (byte)0xac;
        for (int i = start + 18; i + 6 <= data.Length; i++)
        {
            if (data[i] == first && data[i + 1] == second) return i + 6 - start;
        }
        throw PdfReadException.Damaged("A JBIG2 segment of unknown length does not end.");
    }

    private void Process(Segment segment, byte[] data, int start, int end)
    {
        switch (segment.Type)
        {
            case 36 or 38 or 39:
                GenericRegion(segment, data, start, end);
                break;
            case 48:
                PageInformation(data, start, end);
                break;
            case 50:
                EndOfStripe(data, start, end);
                break;
            // Profiles, extensions, end of page and file, and types this reader does not know carry nothing to draw.
        }
    }

    private static Region ReadRegion(byte[] data, int start, int end)
    {
        if (end - start < 17) throw PdfReadException.Damaged("A JBIG2 region segment is cut off.");
        long width = U32(data, start), height = U32(data, start + 4), x = U32(data, start + 8), y = U32(data, start + 12);
        if (width > int.MaxValue || height > int.MaxValue) throw Jbig2Budget.TooBig();
        return new Region((int)width, (int)height, (int)Math.Min(x, int.MaxValue), (int)Math.Min(y, int.MaxValue), data[start + 16] & 7);
    }

    private void GenericRegion(Segment segment, byte[] data, int start, int end)
    {
        var region = ReadRegion(data, start, end);
        if (segment.UnknownLength)
        {
            // The row count the segment ends with is the height that was coded.
            region = region with { Height = (int)Math.Min(region.Height, U32(data, end - 4)) };
            end -= 4;
        }
        int position = start + 17;
        int flags = U8(data, position++);
        bool mmr = (flags & 1) != 0;
        int template = (flags >> 1) & 3;
        bool typicalPrediction = (flags & 8) != 0;
        Jbig2Bitmap bitmap;
        if (mmr)
        {
            bitmap = Jbig2Generic.Mmr(_budget, data, position, end, region.Width, region.Height, out _);
        }
        else
        {
            var at = ReadAt(data, ref position, end, template == 0 ? 4 : 1);
            var arith = new Jbig2Arith(data, position, end);
            bitmap = Jbig2Generic.Decode(_budget, arith, region.Width, region.Height, template, typicalPrediction, null, at);
        }
        Store(segment, region, bitmap);
    }

    /// <summary>An intermediate region is kept for a refinement; an immediate one goes onto the page.</summary>
    private void Store(Segment segment, Region region, Jbig2Bitmap bitmap)
    {
        if (segment.Type is 4 or 20 or 36 or 40)
        {
            _intermediate[segment.Number] = bitmap;
            return;
        }
        Draw(region, bitmap);
    }

    private static int[] ReadAt(byte[] data, ref int position, int end, int pairs)
    {
        if (end - position < pairs * 2) throw PdfReadException.Damaged("A JBIG2 segment is cut off.");
        var at = new int[pairs * 2];
        for (int i = 0; i < at.Length; i++) at[i] = (sbyte)data[position++];
        return at;
    }

    private void PageInformation(byte[] data, int start, int end)
    {
        // A PDF image holds one page; later page information is not for this image.
        if (_page is not null) return;
        if (end - start < 19) throw PdfReadException.Damaged("A JBIG2 page information segment is cut off.");
        long width = U32(data, start), height = U32(data, start + 4);
        int flags = data[start + 16];
        if (width == 0 || width > int.MaxValue) throw PdfReadException.Damaged("A JBIG2 page has no width.");
        _heightKnown = height != 0xffffffffL;
        if (_heightKnown && height > int.MaxValue) throw Jbig2Budget.TooBig();
        _defaultPixel = (byte)((flags >> 2) & 1);
        int rows = _heightKnown ? (int)height : 0;
        _page = new Jbig2Bitmap((int)width, rows, _budget);
        _rows = rows;
        if (_defaultPixel != 0) _page.Fill(1);
    }

    private void EndOfStripe(byte[] data, int start, int end)
    {
        if (end - start < 4) throw PdfReadException.Damaged("A JBIG2 end of stripe segment is cut off.");
        long row = U32(data, start);
        if (_page is null || _heightKnown) return;
        if (row >= int.MaxValue) throw Jbig2Budget.TooBig();
        Reach((int)row + 1);
    }

    /// <summary>Makes room for rows down to <paramref name="rows"/> in a page of unknown height and counts them as used.</summary>
    private void Reach(int rows)
    {
        var page = _page!;
        if (rows > page.Height)
        {
            // Doubling keeps the total of what is allocated, which the budget counts, within twice the page.
            int capacity = (int)Math.Min(Math.Max(rows, page.Height * 2L), int.MaxValue);
            if (page.Width > 0 && capacity > PdfImageSamples.MaxPixels / page.Width) capacity = rows;
            var grown = new Jbig2Bitmap(page.Width, capacity, _budget);
            if (_defaultPixel != 0) grown.Fill(1);
            Array.Copy(page.Pixels, grown.Pixels, page.Pixels.Length);
            _page = page = grown;
        }
        _rows = Math.Max(_rows, rows);
    }

    private void Draw(Region region, Jbig2Bitmap bitmap)
    {
        if (_page is null) throw PdfReadException.Damaged("A JBIG2 region comes before the page information.");
        if (!_heightKnown && region.Y < int.MaxValue - region.Height) Reach(region.Y + region.Height);
        _page.Compose(bitmap, region.X, region.Y, region.Op);
        _drawn++;
    }

    /// <summary>The page as packed rows, black 0.</summary>
    public byte[] Finish()
    {
        if (_page is null) throw _firstError ?? PdfReadException.Damaged("A JBIG2 stream has no page.");
        if (_failed > 0 && _drawn == 0) throw _firstError!;
        int width = _page.Width, rows = _rows;
        int stride = (width + 7) / 8;
        if ((long)rows * stride > maxSize) throw FilterBuffer.TooBig();
        var output = new byte[rows * stride];
        Array.Fill(output, (byte)0xff);
        var pixels = _page.Pixels;
        for (int y = 0; y < rows; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (pixels[y * width + x] != 0) output[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return output;
    }

    private static int U8(byte[] data, int at) =>
        at >= 0 && at < data.Length ? data[at] : throw PdfReadException.Damaged("A JBIG2 segment is cut off.");

    private static int U16(byte[] data, int at) => (U8(data, at) << 8) | U8(data, at + 1);

    private static long U32(byte[] data, int at) => ((long)U16(data, at) << 16) | (uint)U16(data, at + 2);
}
