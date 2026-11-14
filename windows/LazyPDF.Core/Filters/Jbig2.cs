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
    /// A segment that does not decode is left out; the stream is damaged only when none of its regions could be drawn,
    /// or at all when <paramref name="whole"/> says a partial page is no use.
    /// </summary>
    public static byte[] Decode(byte[] globals, byte[] data, long maxSize, int width = 0, int height = 0, bool whole = false)
    {
        // TODO: a budget for all the JBIG2 decodes of a document, so that many images cannot each use a full one.
        var decoder = new Jbig2Decoder(maxSize, width, height, whole);
        decoder.Read(globals, globals: true);
        decoder.Read(data);
        return decoder.Finish();
    }
}

/// <summary>
/// With <paramref name="fitWidth"/> and <paramref name="fitHeight"/> (the size the image dictionary gives) the page comes out
/// cut or padded with white to that size, so that the samples have the stride the image reads them with.
/// </summary>
internal sealed class Jbig2Decoder(long maxSize, int fitWidth = 0, int fitHeight = 0, bool whole = false)
{
    private readonly Jbig2Budget _budget = new();
    private int _segments;
    private int _failed;
    private int _drawn;
    private PdfReadException? _firstError;

    // The page (7.4.8). With an unknown height the bitmap grows with the regions and stripes, and _rows is what is used.
    private Jbig2Bitmap? _page;
    private bool _heightKnown;
    private int _rows;
    private byte _defaultPixel;

    /// <summary>The most segments one decode reads, the globals and the image together.</summary>
    private const int MaxSegments = 1 << 16;

    /// <summary>The shortest segment header: number, flags, referred-to flags, page association and length.</summary>
    private const int MinHeader = 11;

    private readonly Dictionary<long, Jbig2Bitmap> _intermediate = [];
    private readonly Dictionary<long, Jbig2SymbolDictionary> _dictionaries = [];
    private readonly Dictionary<long, Jbig2Huffman> _tables = [];
    private readonly Dictionary<long, List<Jbig2Bitmap>> _patterns = [];

    private readonly record struct Segment(long Number, int Type, long[] Referred, long Length, int HeaderEnd, bool UnknownLength);

    private readonly record struct Region(int Width, int Height, int X, int Y, int Op);

    /// <summary>
    /// What the image's own segments may make is tied to the size of the picture (the globals, which many pictures share,
    /// are not), which have a budget of their own and may hold dictionaries and tables only.
    /// </summary>
    private void StartImage()
    {
        _inGlobals = false;
        _budget.ForImage(fitWidth > 0 && fitHeight > 0 ? (long)fitWidth * fitHeight : 0);
    }

    private bool _inGlobals;

    // How many segments in a row may fail without reading anything of their own before the rest of the data is given up on.
    private const int MaxFailedRun = 16;

    // The end of the segment being read: no field of it is read past that.
    private int _limit;

    /// <summary>The segments of <paramref name="data"/> one after the other (7.2), through the end of file segment.</summary>
    public void Read(byte[] data, bool globals = false)
    {
        _inGlobals = globals;
        if (globals) _budget.ForGlobals();
        else StartImage();
        int position = 0;
        int failedRun = 0;
        // Zeros at the end are padding, a line break or a stray byte after the last segment is the end of the data, not a segment that failed.
        int last = data.AsSpan().LastIndexOfAnyExcept((byte)0);
        while (position <= last)
        {
            if (data.Length - position < MinHeader) return;
            _limit = data.Length;
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
            if (++_segments > MaxSegments) throw Jbig2Budget.TooBig();
            int start = segment.HeaderEnd;
            int end = (int)Math.Min(start + segment.Length, data.Length);
            // A segment that runs past the end of the data is read as far as it goes, unless a partial page is no use.
            if (whole && !segment.UnknownLength && start + segment.Length > data.Length)
            {
                Fail(PdfReadException.Damaged("A JBIG2 segment is cut off."));
                return;
            }
            try
            {
                // The handlers read nothing of the next segment: the fields they take are bounded by the end of this one.
                _limit = end;
                Process(segment, data, start, end);
                failedRun = 0;
            }
            catch (PdfReadException e) when (e.Problem == PdfReadProblem.Damaged)
            {
                Fail(e);
                // A segment that carries data may fail for what an earlier one left out; only empty ones are a run.
                if (segment.Length <= segment.HeaderEnd - position && ++failedRun > MaxFailedRun)
                {
                    Fail(PdfReadException.Damaged("A JBIG2 stream has nothing but segments that do not decode."));
                    return;
                }
            }
            // Nothing after the end of the page or of the file is read.
            if (segment.Type is 49 or 51) return;
            position = end;
        }
    }

    private void Fail(PdfReadException e)
    {
        _failed++;
        _firstError ??= e;
    }

    /// <summary>7.2: the segment header at <paramref name="start"/>.</summary>
    private Segment ReadHeader(byte[] data, int start)
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

    private long UnknownLength(byte[] data, int start)
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
        // The globals of an image hold dictionaries and tables; whatever else is there is not drawn.
        if (_inGlobals && segment.Type is not (0 or 16 or 53)) return;
        switch (segment.Type)
        {
            case 0:
                SymbolDictionary(segment, data, start, end);
                break;
            case 4 or 6 or 7:
                TextRegion(segment, data, start, end);
                break;
            case 16:
                PatternDictionary(segment, data, start, end);
                break;
            case 20 or 22 or 23:
                HalftoneRegion(segment, data, start, end);
                break;
            case 36 or 38 or 39:
                GenericRegion(segment, data, start, end);
                break;
            case 40 or 42 or 43:
                RefinementRegion(segment, data, start, end);
                break;
            case 53:
                _tables[segment.Number] = Jbig2Huffman.Custom(data, start, end);
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

    /// <summary>The symbols the referred dictionaries export, one after the other.</summary>
    private List<Jbig2Bitmap> InputSymbols(Segment segment)
    {
        var symbols = new List<Jbig2Bitmap>();
        foreach (long number in segment.Referred)
        {
            if (!_dictionaries.TryGetValue(number, out var dictionary)) continue;
            symbols.AddRange(dictionary.Exported);
            if (symbols.Count > Jbig2Symbols.MaxSymbols) throw Jbig2Budget.TooBig();
            _budget.Fixed(dictionary.Exported.Count * 8L);
        }
        return symbols;
    }

    /// <summary>The tables segments a segment refers to, in order, for the selections that name a custom table.</summary>
    private sealed class CustomTables(List<Jbig2Huffman> tables)
    {
        private int _next;

        public Jbig2Huffman Next() =>
            _next < tables.Count ? tables[_next++] : throw PdfReadException.Damaged("A JBIG2 segment names a custom table it does not refer to.");
    }

    private CustomTables TablesOf(Segment segment)
    {
        var tables = new List<Jbig2Huffman>();
        foreach (long number in segment.Referred)
        {
            if (_tables.TryGetValue(number, out var table)) tables.Add(table);
        }
        return new CustomTables(tables);
    }

    // Selector 3 is a custom table; the standard ones are numbered from <first>.
    private static Jbig2Huffman Select(int selector, int first, int standardCount, CustomTables custom)
    {
        if (selector < standardCount) return Jbig2Huffman.Standard(first + selector);
        if (selector == 3) return custom.Next();
        throw PdfReadException.Damaged("A JBIG2 segment has a bad Huffman table selection.");
    }

    private void SymbolDictionary(Segment segment, byte[] data, int start, int end)
    {
        int position = start;
        int flags = U16(data, position);
        position += 2;
        var p = new Jbig2SymbolParams
        {
            Huffman = (flags & 1) != 0,
            Refine = (flags & 2) != 0,
            Template = (flags >> 10) & 3,
            RefinementTemplate = (flags >> 12) & 1,
        };
        if (!p.Huffman) p.At = ReadAt(data, ref position, end, p.Template == 0 ? 4 : 1);
        if (p.Refine && p.RefinementTemplate == 0) p.RefinementAt = ReadAt(data, ref position, end, 2);
        long exported = U32(data, position), added = U32(data, position + 4);
        position += 8;
        if (exported > Jbig2Symbols.MaxSymbols || added > Jbig2Symbols.MaxSymbols) throw Jbig2Budget.TooBig();
        p.ExportedCount = (int)exported;
        p.NewCount = (int)added;
        p.Input = InputSymbols(segment);

        if (p.Huffman)
        {
            var custom = TablesOf(segment);
            p.DeltaHeight = Select((flags >> 2) & 3, 4, 2, custom);
            p.DeltaWidth = Select((flags >> 4) & 3, 2, 2, custom);
            p.BitmapSize = (flags & 0x40) != 0 ? custom.Next() : Jbig2Huffman.Standard(1);
            p.AggregateInstances = (flags & 0x80) != 0 ? custom.Next() : Jbig2Huffman.Standard(1);
        }

        // 7.4.2.2: the contexts a dictionary left, if it kept them, are where this one starts.
        byte[]? gb = null, gr = null;
        if ((flags & 0x100) != 0)
        {
            Jbig2SymbolDictionary? last = null;
            foreach (long number in segment.Referred)
            {
                if (_dictionaries.TryGetValue(number, out var d)) last = d;
            }
            if (last is null) throw PdfReadException.Damaged("A JBIG2 symbol dictionary reuses contexts of a dictionary it does not refer to.");
            gb = last.Gb;
            gr = last.Gr;
        }
        Jbig2Arith? arith = null;
        Jbig2Reader? reader = null;
        if (p.Huffman)
        {
            reader = new Jbig2Reader(data, position, end);
            gr?.CopyTo(p.RefineContexts, 0);
        }
        else
        {
            arith = new Jbig2Arith(data, position, end, budget: _budget);
            if (gb is not null) arith.Gb = (byte[])gb.Clone();
            if (gr is not null) arith.Gr = (byte[])gr.Clone();
        }
        var symbols = Jbig2Symbols.Decode(_budget, arith, reader, p);
        // Only a dictionary that says so leaves its contexts behind.
        bool retained = (flags & 0x200) != 0;
        if (retained) _budget.Keep(1 << 17);
        _dictionaries[segment.Number] = new Jbig2SymbolDictionary(symbols, retained ? arith?.Gb : null, retained ? arith?.Gr ?? p.RefineContexts : null);
    }

    private void TextRegion(Segment segment, byte[] data, int start, int end)
    {
        var region = ReadRegion(data, start, end);
        int position = start + 17;
        int flags = U16(data, position);
        position += 2;
        var p = new Jbig2TextParams
        {
            Huffman = (flags & 1) != 0,
            Refine = (flags & 2) != 0,
            LogStripSize = (flags >> 2) & 3,
            ReferenceCorner = (flags >> 4) & 3,
            Transposed = (flags & 0x40) != 0,
            CombinationOperator = (flags >> 7) & 3,
            DefaultPixel = (flags >> 9) & 1,
            // A signed five bit number.
            DsOffset = ((flags >> 10) & 0x1f) - ((flags & 0x4000) != 0 ? 32 : 0),
            RefinementTemplate = (flags >> 15) & 1,
            Width = region.Width,
            Height = region.Height,
        };
        int huffmanFlags = 0;
        if (p.Huffman)
        {
            huffmanFlags = U16(data, position);
            position += 2;
        }
        if (p.Refine && p.RefinementTemplate == 0) p.RefinementAt = ReadAt(data, ref position, end, 2);
        long instances = U32(data, position);
        position += 4;
        if (instances > Jbig2Text.MaxInstances) throw Jbig2Budget.TooBig();
        p.Instances = (int)instances;
        p.Symbols = InputSymbols(segment);
        p.SymbolCodeLength = Jbig2Text.CodeLength(p.Symbols.Count);

        Jbig2Arith? arith = null;
        Jbig2Reader? reader = null;
        if (p.Huffman)
        {
            var custom = TablesOf(segment);
            reader = new Jbig2Reader(data, position, end);
            p.SymbolIds = SymbolIdTable(reader, p.Symbols.Count);
            p.FirstS = Select(huffmanFlags & 3, 6, 2, custom);
            p.DeltaS = Select((huffmanFlags >> 2) & 3, 8, 3, custom);
            p.DeltaT = Select((huffmanFlags >> 4) & 3, 11, 3, custom);
            // The selections for the refinement values mean nothing in a region that does not refine.
            if (p.Refine)
            {
                p.RefineWidth = Select((huffmanFlags >> 6) & 3, 14, 2, custom);
                p.RefineHeight = Select((huffmanFlags >> 8) & 3, 14, 2, custom);
                p.RefineX = Select((huffmanFlags >> 10) & 3, 14, 2, custom);
                p.RefineY = Select((huffmanFlags >> 12) & 3, 14, 2, custom);
                p.RefineSize = (huffmanFlags & 0x4000) != 0 ? custom.Next() : Jbig2Huffman.Standard(1);
            }
        }
        else
        {
            arith = new Jbig2Arith(data, position, end, budget: _budget);
            _budget.Fixed(2L << p.SymbolCodeLength);
        }
        var bitmap = new Jbig2Text(_budget, arith, reader, p, p.Huffman ? new byte[1 << 13] : null).Decode();
        Store(segment, region, bitmap);
    }

    /// <summary>7.4.3.1.7: the code lengths of the symbols, themselves coded with a table of 35 run codes.</summary>
    private static Jbig2Huffman SymbolIdTable(Jbig2Reader reader, int count)
    {
        var runLengths = new int[35];
        for (int i = 0; i < runLengths.Length; i++) runLengths[i] = (int)reader.ReadBits(4);
        var runCodes = Jbig2Huffman.ForLengths(runLengths);
        var lengths = new int[count];
        for (int i = 0; i < count;)
        {
            if (!runCodes.Decode(reader, out int code)) throw PdfReadException.Damaged("A JBIG2 symbol code table has an out-of-band value.");
            int repeat, length;
            switch (code)
            {
                case < 32:
                    lengths[i++] = code;
                    continue;
                case 32:
                    if (i == 0) throw PdfReadException.Damaged("A JBIG2 symbol code table repeats nothing.");
                    repeat = (int)reader.ReadBits(2) + 3;
                    length = lengths[i - 1];
                    break;
                case 33:
                    repeat = (int)reader.ReadBits(3) + 3;
                    length = 0;
                    break;
                default:
                    repeat = (int)reader.ReadBits(7) + 11;
                    length = 0;
                    break;
            }
            if (repeat > count - i) throw PdfReadException.Damaged("A JBIG2 symbol code table is too long.");
            for (int j = 0; j < repeat; j++) lengths[i++] = length;
        }
        reader.ByteAlign();
        return Jbig2Huffman.ForLengths(lengths);
    }

    private void RefinementRegion(Segment segment, byte[] data, int start, int end)
    {
        var region = ReadRegion(data, start, end);
        int position = start + 17;
        int flags = U8(data, position++);
        int template = flags & 1;
        int[] at = template == 0 ? ReadAt(data, ref position, end, 2) : [-1, -1, -1, -1];
        Jbig2Bitmap? reference = null;
        foreach (long number in segment.Referred)
        {
            if (_intermediate.TryGetValue(number, out var found)) reference = found;
        }
        if (reference is null)
        {
            // Nothing referred to: the page under the region is what gets refined.
            if (_page is null) throw PdfReadException.Damaged("A JBIG2 refinement region comes before the page information.");
            reference = new Jbig2Bitmap(region.Width, region.Height, _budget);
            reference.Compose(_page, -region.X, -region.Y, 4);
        }
        else if (reference.Width != region.Width || reference.Height != region.Height)
        {
            throw PdfReadException.Damaged("A JBIG2 refinement region is not the size of the region it refines.");
        }
        var arith = new Jbig2Arith(data, position, end, budget: _budget);
        var bitmap = Jbig2Generic.Refine(_budget, arith, region.Width, region.Height, template, reference, 0, 0, (flags & 2) != 0, at);
        Store(segment, region, bitmap);
    }

    private void PatternDictionary(Segment segment, byte[] data, int start, int end)
    {
        int flags = U8(data, start);
        int width = U8(data, start + 1), height = U8(data, start + 2);
        long maxIndex = U32(data, start + 3);
        _patterns[segment.Number] = Jbig2Halftone.Patterns(_budget, data, start + 7, end, (flags & 1) != 0, (flags >> 1) & 3, width, height, maxIndex);
    }

    private void HalftoneRegion(Segment segment, byte[] data, int start, int end)
    {
        var region = ReadRegion(data, start, end);
        int position = start + 17;
        int flags = U8(data, position++);
        var p = new Jbig2Halftone.Params
        {
            Mmr = (flags & 1) != 0,
            Template = (flags >> 1) & 3,
            EnableSkip = (flags & 8) != 0,
            CombinationOperator = (flags >> 4) & 7,
            DefaultPixel = (flags >> 7) & 1,
            Width = region.Width,
            Height = region.Height,
            GridWidth = U32(data, position),
            GridHeight = U32(data, position + 4),
            GridX = (int)U32(data, position + 8),
            GridY = (int)U32(data, position + 12),
            VectorX = U16(data, position + 16),
            VectorY = U16(data, position + 18),
        };
        position += 20;
        List<Jbig2Bitmap>? patterns = null;
        foreach (long number in segment.Referred)
        {
            if (_patterns.TryGetValue(number, out var found)) patterns = found;
        }
        if (patterns is null) throw PdfReadException.Damaged("A JBIG2 halftone region has no pattern dictionary.");
        Store(segment, region, Jbig2Halftone.Region(_budget, data, position, end, p, patterns));
    }

    private Region ReadRegion(byte[] data, int start, int end, bool heightFollows = false)
    {
        if (end - start < 17) throw PdfReadException.Damaged("A JBIG2 region segment is cut off.");
        long width = U32(data, start), height = U32(data, start + 4), x = U32(data, start + 8), y = U32(data, start + 12);
        // A region of unknown length may give an unknown height too; the row count it ends with says it.
        if (heightFollows) height = Math.Min(height, int.MaxValue);
        if (width > int.MaxValue || height > int.MaxValue) throw Jbig2Budget.TooBig();
        return new Region((int)width, (int)height, (int)Math.Min(x, int.MaxValue), (int)Math.Min(y, int.MaxValue), data[start + 16] & 7);
    }

    private void GenericRegion(Segment segment, byte[] data, int start, int end)
    {
        var region = ReadRegion(data, start, end, segment.UnknownLength);
        if (segment.UnknownLength)
        {
            if (end - start < 22) throw PdfReadException.Damaged("A JBIG2 region segment is cut off.");
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
            var arith = new Jbig2Arith(data, position, end, budget: _budget);
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
        // The page is about to be allocated: a page whose rows alone pass the limit is refused first.
        if (_heightKnown && height * ((width + 7) / 8) > maxSize) throw FilterBuffer.TooBig();
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
            // Doubling must not take a page that fits past the limit.
            if (page.Width > 0 && capacity > PdfImageSamples.MaxPixels / page.Width) capacity = (int)Math.Max(rows, PdfImageSamples.MaxPixels / page.Width);
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
        // A page that is not whole is wrong in the parts that failed; only some callers can use it.
        if (_failed > 0 && (_drawn == 0 || whole)) throw _firstError!;
        int width = _page.Width, rows = _rows;
        bool fit = fitWidth > 0 && fitHeight > 0;
        int outWidth = fit ? fitWidth : width, outRows = fit ? fitHeight : rows;
        int stride = (outWidth + 7) / 8;
        if ((long)outRows * stride > maxSize) throw FilterBuffer.TooBig();
        var output = new byte[outRows * stride];
        Array.Fill(output, (byte)0xff);
        var pixels = _page.Pixels;
        for (int y = 0; y < Math.Min(rows, outRows); y++)
        {
            for (int x = 0; x < Math.Min(width, outWidth); x++)
            {
                if (pixels[y * width + x] != 0) output[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return output;
    }

    private int U8(byte[] data, int at) =>
        at >= 0 && at < data.Length && at < _limit ? data[at] : throw PdfReadException.Damaged("A JBIG2 segment is cut off.");

    private int U16(byte[] data, int at) => (U8(data, at) << 8) | U8(data, at + 1);

    private long U32(byte[] data, int at) => ((long)U16(data, at) << 16) | (uint)U16(data, at + 2);
}
