using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// JPEG 2000 through the bundled openjp2.dll (OpenJPEG), for the pictures Windows has no codec for. Any
/// failure, a missing DLL included, is a null: the caller treats the picture as one it cannot read.
/// </summary>
internal static class OpenJpeg
{
    private const string Library = "openjp2";
    private const int J2k = 0, Jp2 = 2;
    private const int ClrSycc = 3, ClrEycc = 4, ClrCmyk = 5, ClrGray = 2, ClrSrgb = 1;

    // Room for opj_dparameters_t, which is 8252 bytes.
    private const int DecoderParametersSize = 8300;
    private const int MaxComponents = 5;
    private const int FlagsOffset = 8248, IgnoreColourBoxes = 1;
    private const long MaxTileSamples = 1 << 16;
    private const int MaxLayers = 1024, MaxLevels = 32;
    // The packets of all tiles OpenJPEG may be asked to walk. A real picture has a few dozen layers at most and precincts of
    // 2^7 or the default, so a 16384 x 8192 RGB picture of 30 layers in 128 pixel precincts is about 1 million. The memory
    // budget does not limit this work, which runs at some millions of packets a second.
    private const long MaxPackets = 1 << 22;
    // What one decode may allocate inside OpenJPEG: the image and the tile buffers of the largest picture accepted, plus slack.
    internal const long DecodeBudget = 8 * PdfImageSamples.MaxPixels + (128L << 20);

    private static readonly byte[] Jp2Signature = [0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A];
    private static readonly MessageFn Quiet = (_, _) => { };

    // The DLL is loaded from the app's own folder by full path, never found through the current directory or PATH.
    // A build without a runtime identifier carries one per architecture under runtimes; a build for one has it beside the exe.
    static OpenJpeg() => NativeLibrary.SetDllImportResolver(typeof(OpenJpeg).Assembly, Resolve);

    private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != Library) return IntPtr.Zero;
        string arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";
        string folder = AppContext.BaseDirectory;
        foreach (string file in new[] { Path.Combine(folder, "runtimes", arch, "native", "openjp2.dll"), Path.Combine(folder, "openjp2.dll") })
        {
            if (NativeLibrary.TryLoad(file, out var handle)) return handle;
        }
        throw new DllNotFoundException("openjp2.dll");
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate nuint ReadFn(IntPtr buffer, nuint count, IntPtr user);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate long SkipFn(long count, IntPtr user);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int SeekFn(long position, IntPtr user);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void MessageFn(IntPtr message, IntPtr user);

    [StructLayout(LayoutKind.Sequential)]
    private struct Component
    {
        public uint Dx, Dy, W, H, X0, Y0, Prec, Bpp, Sgnd, ResnoDecoded, Factor;
        public IntPtr Data;
        public ushort Alpha;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Image
    {
        public uint X0, Y0, X1, Y1, NumComps;
        public int ColorSpace;
        public IntPtr Comps, IccBuffer;
        public uint IccLength;
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void lazypdf_opj_budget(nuint bytes);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern nuint lazypdf_opj_used();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_codec_set_threads(IntPtr codec, int threads);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr opj_create_decompress(int format);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_destroy_codec(IntPtr codec);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_set_default_decoder_parameters(IntPtr parameters);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_setup_decoder(IntPtr codec, IntPtr parameters);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_decoder_set_strict_mode(IntPtr codec, int strict);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_set_info_handler(IntPtr codec, MessageFn handler, IntPtr user);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_set_warning_handler(IntPtr codec, MessageFn handler, IntPtr user);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_set_error_handler(IntPtr codec, MessageFn handler, IntPtr user);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr opj_stream_create(nuint bufferSize, int input);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_destroy(IntPtr stream);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_read_function(IntPtr stream, ReadFn read);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_skip_function(IntPtr stream, SkipFn skip);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_seek_function(IntPtr stream, SeekFn seek);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_user_data_length(IntPtr stream, ulong length);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_read_header(IntPtr stream, IntPtr codec, out IntPtr image);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_decode(IntPtr codec, IntPtr stream, IntPtr image);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_end_decompress(IntPtr codec, IntPtr stream);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_image_destroy(IntPtr image);

    /// <summary>
    /// A JPEG 2000 file or codestream as RGBA, or null when it cannot be read, is a CIELab picture, or would hold more than
    /// <see cref="PdfImageSamples.MaxPixels"/> samples of 4 bytes while decoded (a palette makes new components out of one).
    /// <paramref name="components"/> is the colour space's component count from the PDF, 0 when it is not known.
    /// </summary>
    public static PdfRgbaImage? Decode(byte[] data, int components = 0) => Decode(data, components, DecodeBudget);

    internal static PdfRgbaImage? Decode(byte[] data, int components, long budget)
    {
        int format = Format(data);
        if (format < 0 || !ReadStructure(data, format, out var colour)) return null;
        IntPtr parameters = IntPtr.Zero, codec = IntPtr.Zero, stream = IntPtr.Zero, image = IntPtr.Zero;
        bool budgeted = false;
        var source = new Source(data);
        ReadFn read = source.Read;
        SkipFn skip = source.Skip;
        SeekFn seek = source.Seek;
        try
        {
            parameters = Marshal.AllocHGlobal(DecoderParametersSize);
            opj_set_default_decoder_parameters(parameters);
            // Palette and channel boxes are applied below, so OpenJPEG never expands a palette itself.
            Marshal.WriteInt32(parameters, FlagsOffset, Marshal.ReadInt32(parameters, FlagsOffset) | IgnoreColourBoxes);
            // The budget is per thread, so every call of one decode stays on this one.
            lazypdf_opj_budget((nuint)budget);
            budgeted = true;
            codec = opj_create_decompress(format);
            if (codec == IntPtr.Zero) return null;
            if (opj_codec_set_threads(codec, 0) == 0) return null;
            opj_set_info_handler(codec, Quiet, IntPtr.Zero);
            opj_set_warning_handler(codec, Quiet, IntPtr.Zero);
            opj_set_error_handler(codec, Quiet, IntPtr.Zero);
            if (opj_setup_decoder(codec, parameters) == 0) return null;
            // A cut-off stream gives the part that arrived instead of nothing, as a viewer shows it.
            opj_decoder_set_strict_mode(codec, 0);

            stream = opj_stream_create(1 << 16, 1);
            if (stream == IntPtr.Zero) return null;
            opj_stream_set_read_function(stream, read);
            opj_stream_set_skip_function(stream, skip);
            opj_stream_set_seek_function(stream, seek);
            opj_stream_set_user_data_length(stream, (ulong)data.Length);

            if (opj_read_header(stream, codec, out image) == 0 || image == IntPtr.Zero) return null;
            var header = Marshal.PtrToStructure<Image>(image);
            long width = (long)header.X1 - header.X0, height = (long)header.Y1 - header.Y0;
            if (width < 1 || height < 1 || width * height > PdfImageSamples.MaxPixels || header.NumComps is 0 or > MaxComponents) return null;
            if (IsLab(header) || Channels((int)header.NumComps, colour) is not { } channels || !WithinBudget(header, channels, colour.Palette is not null && colour.Mappings is not null)) return null;

            if (opj_decode(codec, stream, image) == 0 || opj_end_decompress(codec, stream) == 0) return null;
            return ToRgba(Marshal.PtrToStructure<Image>(image), channels, colour.Palette, (int)width, (int)height, components);
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            if (codec != IntPtr.Zero) opj_destroy_codec(codec);
            if (stream != IntPtr.Zero) opj_stream_destroy(stream);
            if (image != IntPtr.Zero) opj_image_destroy(image);
            if (budgeted) lazypdf_opj_budget(0);
            if (parameters != IntPtr.Zero) Marshal.FreeHGlobal(parameters);
            GC.KeepAlive(read);
            GC.KeepAlive(skip);
            GC.KeepAlive(seek);
        }
    }

    private static int Format(byte[] data)
    {
        if (data.Length >= 12 && data.AsSpan(0, 12).SequenceEqual(Jp2Signature)) return Jp2;
        if (data.Length >= 4 && data[0] == 0xFF && data[1] == 0x4F && data[2] == 0xFF && data[3] == 0x51) return J2k;
        return -1;
    }

    // OpenJPEG hands CIELab on as an unknown colour space whose buffer starts with the enumerated space, 14, and has no length.
    private static bool IsLab(Image image) => image.IccBuffer != IntPtr.Zero && image.IccLength == 0 && Marshal.ReadInt32(image.IccBuffer) == 14;

    private sealed record Palette(int Entries, int Columns, int[] Size, bool[] Signed, uint[] Values);

    private sealed record Mapping(int Component, int Type, int Column);

    private readonly record struct Definition(int Channel, int Type, int Association);

    // What the colour boxes of a JP2 file ask for. A palette counts only together with its component mapping.
    private sealed record Colour(Palette? Palette, Mapping[]? Mappings, Definition[]? Definitions);

    // One channel of the picture: a codestream component, or a column of the palette read through one. A Prec of 0 means the
    // component's own depth; with a palette the depth and sign come from the palette box, direct channels included.
    private sealed class Channel(int source, bool mapped, int column, int prec, bool signed)
    {
        public int Source = source, Column = column, Prec = prec;
        public bool Mapped = mapped, Signed = signed;
        public int Kind;
        public Component Comp;
    }

    private static readonly Colour NoColour = new(null, null, null);

    // Reads what OpenJPEG would use of the file's boxes, and gives false for what it would refuse and for a layout that puts
    // colour boxes where the library reads them without looking at their place. The SIZ of the codestream is checked before the
    // library sees it, since it allocates a record per tile and per component of every tile while reading the header.
    private static bool ReadStructure(byte[] file, int format, out Colour colour)
    {
        colour = NoColour;
        int codestream = 0;
        if (format == Jp2)
        {
            bool header = false;
            codestream = -1;
            for (long p = 0; p + 8 <= file.Length && codestream < 0;)
            {
                if (!ReadBox(file, p, file.Length, out string type, out int at, out long end)) return false;
                if (type == "jp2c")
                {
                    if (!header) return false;
                    codestream = at;
                    continue;
                }
                if (end > file.Length) return false;
                if (type == "jp2h")
                {
                    if (header || !ReadColour(file, at, (int)end, out colour)) return false;
                    header = true;
                }
                else if (type is "ihdr" or "colr" or "bpcc" or "pclr" or "cmap" or "cdef") return false;
                p = end;
            }
            if (codestream < 0) return false;
        }
        return Siz(file, codestream) is { } frame && WithinPackets(file, frame);
    }

    // The type of the box at p and where its content starts and ends. A length of 0 runs to the end.
    private static bool ReadBox(byte[] file, long p, long to, out string type, out int at, out long end)
    {
        type = "";
        at = 0;
        end = 0;
        if (p + 8 > to) return false;
        long length = U32(file, p);
        int header = 8;
        if (length == 1)
        {
            if (p + 16 > to) return false;
            length = 0;
            for (int i = 8; i < 16; i++) length = length << 8 | file[p + i];
            header = 16;
        }
        else if (length == 0) length = to - p;
        if (length < header) return false;
        type = Encoding.Latin1.GetString(file, (int)p + 4, 4);
        at = (int)p + header;
        end = p + length;
        return true;
    }

    private static int U16(byte[] d, long at) => d[at] << 8 | d[at + 1];

    private static uint U32(byte[] d, long at) => (uint)d[at] << 24 | (uint)d[at + 1] << 16 | (uint)d[at + 2] << 8 | d[at + 3];

    // The boxes of the JP2 header, read as OpenJPEG reads them; false where it would fail.
    private static bool ReadColour(byte[] file, int from, int to, out Colour colour)
    {
        colour = NoColour;
        Palette? palette = null;
        Mapping[]? mappings = null;
        Definition[]? definitions = null;
        for (long p = from; p < to;)
        {
            if (!ReadBox(file, p, to, out string type, out int at, out long end) || end > to) return false;
            long size = end - at;
            if (type == "pclr")
            {
                if (palette is not null || size < 3) return false;
                int entries = U16(file, at), columns = file[at + 2];
                if (entries is 0 or > 1024 || columns == 0 || size < 3 + columns) return false;
                var bits = new int[columns];
                var signed = new bool[columns];
                for (int i = 0; i < columns; i++)
                {
                    bits[i] = (file[at + 3 + i] & 0x7F) + 1;
                    signed[i] = (file[at + 3 + i] & 0x80) != 0;
                }
                var values = new uint[entries * columns];
                long q = at + 3 + columns;
                for (int i = 0; i < values.Length; i++)
                {
                    int bytes = Math.Min(4, (bits[i % columns] + 7) >> 3);
                    if (q + bytes > end) return false;
                    uint value = 0;
                    for (int k = 0; k < bytes; k++) value = value << 8 | file[q++];
                    values[i] = value;
                }
                palette = new Palette(entries, columns, bits, signed, values);
            }
            else if (type == "cmap")
            {
                if (palette is null || mappings is not null || size < palette.Columns * 4) return false;
                mappings = [.. Enumerable.Range(0, palette.Columns).Select(i => new Mapping(U16(file, at + 4 * i), file[at + 4 * i + 2], file[at + 4 * i + 3]))];
            }
            else if (type == "cdef")
            {
                if (definitions is not null || size < 2) return false;
                int n = U16(file, at);
                if (n == 0 || size < 2 + n * 6) return false;
                definitions = [.. Enumerable.Range(0, n).Select(i => new Definition(U16(file, at + 2 + 6 * i), U16(file, at + 4 + 6 * i), U16(file, at + 6 + 6 * i)))];
            }
            p = end;
        }
        colour = new Colour(palette, mappings, definitions);
        return true;
    }

    private sealed record Frame(long X, long Y, long X0, long Y0, long TX, long TY, long TX0, long TY0, long[] Dx, long[] Dy, int End)
    {
        public long Across => (X - TX0 + TX - 1) / TX;

        public long Tiles => Across * ((Y - TY0 + TY - 1) / TY);
    }

    // The coding style of one component: its decomposition levels and, for each resolution, the precinct exponents (width in the
    // low nibble, height in the high one). No list means the default of 2^15.
    private sealed record Style(int Levels, byte[]? Precincts);

    // The layers and styles of a tile or of the main header. A COC for a component beats a COD, wherever each one stands.
    private sealed class Coding(int components)
    {
        private readonly bool[] own = new bool[components];
        public int Layers;
        public readonly Style?[] Styles = new Style?[components];

        public Coding(Coding main) : this(main.Styles.Length)
        {
            Layers = main.Layers;
            main.Styles.CopyTo(Styles, 0);
        }

        public void Cod(int layers, Style style)
        {
            Layers = layers;
            for (int c = 0; c < Styles.Length; c++)
            {
                if (!own[c]) Styles[c] = style;
            }
        }

        public void Coc(int component, Style style)
        {
            Styles[component] = style;
            own[component] = true;
        }
    }

    // The SIZ marker segment, which must follow SOC. Refuses what OpenJPEG would refuse, and a header that makes it allocate a lot
    // before any budget is looked at: more components than a picture here may have, or a great many tiles.
    private static Frame? Siz(byte[] d, int at)
    {
        const int Fixed = 38;
        if (at < 0 || (long)at + 4 + Fixed > d.Length || d[at] != 0xFF || d[at + 1] != 0x4F || d[at + 2] != 0xFF || d[at + 3] != 0x51) return null;
        int p = at + 4, count = U16(d, p + 36);
        if (count is 0 or > MaxComponents || U16(d, p) != Fixed + 3 * count || (long)p + Fixed + 3 * count > d.Length) return null;
        long x = U32(d, p + 4), y = U32(d, p + 8), x0 = U32(d, p + 12), y0 = U32(d, p + 16);
        long tx = U32(d, p + 20), ty = U32(d, p + 24), tx0 = U32(d, p + 28), ty0 = U32(d, p + 32);
        if (x <= x0 || y <= y0 || tx == 0 || ty == 0 || tx0 > x0 || ty0 > y0 || tx0 + tx <= x0 || ty0 + ty <= y0) return null;
        var dx = new long[count];
        var dy = new long[count];
        for (int i = 0; i < count; i++)
        {
            dx[i] = d[p + Fixed + 3 * i + 1];
            dy[i] = d[p + Fixed + 3 * i + 2];
            if (dx[i] == 0 || dy[i] == 0) return null;
        }
        long width = x - x0, height = y - y0;
        if (width > PdfImageSamples.MaxPixels || height > PdfImageSamples.MaxPixels || width * height > PdfImageSamples.MaxPixels) return null;
        var frame = new Frame(x, y, x0, y0, tx, ty, tx0, ty0, dx, dy, p + Fixed + 3 * count);
        return frame.Across <= MaxTileSamples && frame.Tiles <= MaxTileSamples && frame.Tiles * count <= MaxTileSamples ? frame : null;
    }

    // The checks on a bare codestream before OpenJPEG reads it: its SIZ, and the packets its tiles would have to walk.
    internal static bool Plausible(byte[] codestream) => Siz(codestream, 0) is { } frame && WithinPackets(codestream, frame);

    // Reads the main header and every tile-part header, following each SOT to the next tile-part, and refuses a codestream whose
    // tiles hold more than MaxPackets packets (ITU-T T.800 B.6) or whose COD or COC OpenJPEG would refuse.
    private static bool WithinPackets(byte[] d, Frame frame)
    {
        int count = frame.Dx.Length;
        var main = new Coding(count);
        bool cod = false;
        long p = frame.End;
        for (; ; p += 2 + U16(d, p + 2))
        {
            if (p + 4 > d.Length) return false;
            int marker = U16(d, p);
            if (marker == 0xFF90) break;
            if (marker >> 8 != 0xFF || U16(d, p + 2) < 2 || p + 2 + U16(d, p + 2) > d.Length) return false;
            if (!ReadStyle(d, p, count, marker, main)) return false;
            cod |= marker == 0xFF52;
        }
        if (!cod) return false;

        var tiles = new Dictionary<long, Coding>();
        while (p + 12 <= d.Length && U16(d, p) == 0xFF90)
        {
            long tile = U16(d, p + 4), part = U32(d, p + 6);
            if (U16(d, p + 2) != 10 || tile >= frame.Tiles || part is > 0 and < 14) return false;
            long end = part == 0 ? d.Length : Math.Min(part + p, d.Length);
            if (!tiles.TryGetValue(tile, out var coding)) tiles[tile] = coding = new Coding(main);
            long q = p + 12;
            for (; ; q += 2 + U16(d, q + 2))
            {
                if (q + 2 > end) return false;
                int marker = U16(d, q);
                if (marker == 0xFF93) break;
                if (q + 4 > end || marker >> 8 != 0xFF || U16(d, q + 2) < 2 || q + 2 + U16(d, q + 2) > end) return false;
                if (!ReadStyle(d, q, count, marker, coding)) return false;
            }
            p = end;
        }

        long packets = 0;
        foreach (var (tile, coding) in tiles)
        {
            packets += Packets(frame, tile, coding);
            if (packets > MaxPackets) return false;
        }
        return true;
    }

    // A COD or COC segment at p goes into the coding; any other marker is left alone. False for one OpenJPEG would refuse.
    private static bool ReadStyle(byte[] d, long p, int count, int marker, Coding coding)
    {
        if (marker is not (0xFF52 or 0xFF53)) return true;
        bool isCod = marker == 0xFF52;
        long at = p + 4, size = U16(d, p + 2) - 2;
        int skip = isCod ? 0 : 1, component = 0;
        // A COD has Scod and then the progression order, layers and colour transform; a COC has the component and Scoc.
        long head = isCod ? 5 : 1, spcod = at + skip + head;
        if (size < skip + head + 5) return false;
        if (!isCod)
        {
            component = d[at];
            if (component >= count) return false;
        }
        int layers = isCod ? U16(d, at + 2) : 1, levels = d[spcod];
        int xcb = d[spcod + 1] + 2, ycb = d[spcod + 2] + 2;
        if (layers is < 1 or > MaxLayers || levels > MaxLevels || xcb > 10 || ycb > 10 || xcb + ycb > 12) return false;
        byte[]? precincts = null;
        if ((d[at + skip] & 1) != 0)
        {
            if (size < skip + head + 5 + levels + 1) return false;
            precincts = d[(int)(spcod + 5)..(int)(spcod + 6 + levels)];
            // An exponent of 0 is only for the lowest resolution (Table A.21).
            for (int i = 1; i < precincts.Length; i++)
            {
                if ((precincts[i] & 15) == 0 || precincts[i] >> 4 == 0) return false;
            }
        }
        var style = new Style(levels, precincts);
        if (isCod) coding.Cod(layers, style);
        else coding.Coc(component, style);
        return true;
    }

    private static long CeilDiv(long value, long by) => (value + by - 1) / by;

    private static long CeilShift(long value, int shift) => (value + (1L << shift) - 1) >> shift;

    // Packets of one tile: its layers times the precincts of every resolution of every component (T.800 B.6).
    private static long Packets(Frame frame, long tile, Coding coding)
    {
        long p = tile % frame.Across, q = tile / frame.Across;
        long x0 = Math.Max(frame.TX0 + p * frame.TX, frame.X0), x1 = Math.Min(frame.TX0 + (p + 1) * frame.TX, frame.X);
        long y0 = Math.Max(frame.TY0 + q * frame.TY, frame.Y0), y1 = Math.Min(frame.TY0 + (q + 1) * frame.TY, frame.Y);
        long precincts = 0;
        for (int c = 0; c < frame.Dx.Length; c++)
        {
            var style = coding.Styles[c]!;
            long cx0 = CeilDiv(x0, frame.Dx[c]), cx1 = CeilDiv(x1, frame.Dx[c]), cy0 = CeilDiv(y0, frame.Dy[c]), cy1 = CeilDiv(y1, frame.Dy[c]);
            for (int r = 0; r <= style.Levels; r++)
            {
                int level = style.Levels - r;
                long rx0 = CeilShift(cx0, level), rx1 = CeilShift(cx1, level), ry0 = CeilShift(cy0, level), ry1 = CeilShift(cy1, level);
                int px = style.Precincts is null ? 15 : style.Precincts[r] & 15, py = style.Precincts is null ? 15 : style.Precincts[r] >> 4;
                long wide = rx1 > rx0 ? CeilShift(rx1, px) - (rx0 >> px) : 0, high = ry1 > ry0 ? CeilShift(ry1, py) - (ry0 >> py) : 0;
                precincts += wide * high;
            }
        }
        return precincts * coding.Layers;
    }

    // The channels the picture has once the palette and channel definitions are applied, as OpenJPEG would make them; null where
    // it would refuse the file. numComps is the codestream's component count.
    private static Channel[]? Channels(int numComps, Colour colour)
    {
        var palette = colour.Palette;
        var mappings = colour.Mappings;
        bool mapped = palette is not null && mappings is not null;
        int count = mapped ? palette!.Columns : numComps;

        if (colour.Definitions is { } checking)
        {
            // Every channel is defined at least once and none more than a few times over; more is not a picture.
            if (checking.Length < count || checking.Length > 4 * count) return null;
            var defined = new bool[count];
            foreach (var d in checking)
            {
                if (d.Channel >= count || d.Association is > 0 and not 65535 && d.Association - 1 >= count) return null;
                defined[d.Channel] = true;
            }
            if (defined.Contains(false)) return null;
        }

        var channels = new Channel[count];
        if (mapped)
        {
            var used = new bool[count];
            bool sane = true;
            for (int i = 0; i < count; i++)
            {
                var (component, type, column) = mappings![i];
                if (component >= numComps) sane = false;
                if (type is not (0 or 1) || column >= count) sane = false;
                else if (used[column] && type == 1) sane = false;
                else if (type == 0 && column != 0) sane = false;
                else if (type == 1 && column != i) sane = false;
                else used[column] = true;
            }
            for (int i = 0; i < count; i++)
            {
                if (!used[i] && mappings![i].Type != 0) sane = false;
            }
            if (!sane || palette!.Size.Any(bits => bits > 16)) return null;
            // A one-component picture whose mapping leaves a column out is read as a plain palette.
            bool plain = numComps == 1 && used.Contains(false);
            for (int i = 0; i < count; i++) channels[i] = new Channel(mappings![i].Component, plain || mappings[i].Type == 1, i, palette.Size[i], palette.Signed[i]);
        }
        else
        {
            for (int i = 0; i < count; i++) channels[i] = new Channel(i, false, 0, 0, false);
        }

        if (colour.Definitions is { } definitions)
        {
            // A swap moves the channels that later entries name too: where[c] is where the channel an entry calls c stands now.
            var where = Enumerable.Range(0, count).ToArray();
            var who = (int[])where.Clone();
            foreach (var info in definitions)
            {
                int cn = where[info.Channel], asoc = info.Association;
                if (asoc is 0 or 65535)
                {
                    channels[cn].Kind = info.Type;
                    continue;
                }
                int acn = asoc - 1;
                if (cn != acn && info.Type == 0)
                {
                    (channels[cn], channels[acn]) = (channels[acn], channels[cn]);
                    (who[cn], who[acn]) = (who[acn], who[cn]);
                    where[who[cn]] = cn;
                    where[who[acn]] = acn;
                }
                channels[cn].Kind = info.Type;
            }
        }
        return channels;
    }

    // The decoder keeps 4 bytes per sample of every codestream component. A palette's channels are counted on top, though they
    // are read through their source component and never copied, so together they stay within what a picture at the pixel cap
    // takes in 4-byte samples.
    private static bool WithinBudget(Image image, Channel[] channels, bool palette)
    {
        int count = (int)image.NumComps;
        var sizes = new long[count];
        long total = 0;
        for (int i = 0; i < count; i++)
        {
            var c = Marshal.PtrToStructure<Component>(image.Comps + i * Marshal.SizeOf<Component>());
            if (c.W > PdfImageSamples.MaxPixels || c.H > PdfImageSamples.MaxPixels) return false;
            sizes[i] = (long)c.W * c.H;
            total += sizes[i];
        }
        if (channels.Length > MaxComponents) return false;
        foreach (var channel in channels)
        {
            if (channel.Source >= count) return false;
            if (palette) total += sizes[channel.Source];
        }
        return total <= PdfImageSamples.MaxPixels;
    }

    private static PdfRgbaImage? ToRgba(Image image, Channel[] channels, Palette? palette, int width, int height, int hint)
    {
        int count = channels.Length;
        if (count is 0 or > MaxComponents) return null;
        var sources = new Component[image.NumComps];
        for (int i = 0; i < sources.Length; i++)
        {
            sources[i] = Marshal.PtrToStructure<Component>(image.Comps + i * Marshal.SizeOf<Component>());
            ref var c = ref sources[i];
            if (c.Data == IntPtr.Zero || c.Dx < 1 || c.Dy < 1 || c.W < 1 || c.H < 1) return null;
            if (c.W > (width + c.Dx - 1) / c.Dx + 1 || c.H > (height + c.Dy - 1) / c.Dy + 1) return null;
        }
        var comps = new Component[count];
        for (int i = 0; i < count; i++)
        {
            var channel = channels[i];
            comps[i] = channel.Comp = sources[channel.Source];
            if (channel.Prec == 0)
            {
                channel.Prec = (int)comps[i].Prec;
                channel.Signed = comps[i].Sgnd != 0;
            }
            if (channel.Prec is < 1 or > 16) return null;
        }

        int space = image.ColorSpace;
        // A YCC picture is the one whose chroma is subsampled differently from its luma, whatever the header says.
        if (count == 3 && space is not (ClrSycc or ClrEycc) && (comps[1].Dx != comps[0].Dx || comps[1].Dy != comps[0].Dy)) space = ClrSycc;

        // A channel definition gives each component a type: 0 colour, 1 opacity, 2 premultiplied opacity, 65535 unspecified.
        // When none says colour or opacity, the definition tells nothing and every component is colour.
        var kinds = channels.Select(c => c.Kind).ToArray();
        if (kinds.All(k => k is not (0 or 1 or 2))) Array.Clear(kinds);
        var alphas = Enumerable.Range(0, count).Where(i => kinds[i] is 1 or 2).ToList();
        int alpha = alphas.Count > 0 ? alphas[0] : -1;
        var colour = Enumerable.Range(0, count).Where(i => kinds[i] == 0).ToList();
        if (alpha < 0 && !kinds.Any(k => k is not 0))
        {
            // The PDF's colour space says how many components are colour; one more is opacity.
            bool known = space is ClrGray or ClrSrgb or ClrSycc or ClrEycc;
            if (hint > 0 ? count == hint + 1 : count == 2 || known && count is 2 or 4) alpha = count - 1;
            if (alpha >= 0) colour.Remove(alpha);
        }
        bool premultiplied = alpha >= 0 && kinds[alpha] == 2;
        if (colour.Count is 2) colour.RemoveAt(1);
        if (colour.Count is not (1 or 3 or 4)) return null;
        bool cmyk = colour.Count == 4;

        var luts = new byte[count][];
        for (int i = 0; i < count; i++) luts[i] = Lut(channels[i].Prec);

        var rgba = new byte[width * height * 4];
        var rows = new int[count][];
        for (int i = 0; i < count; i++) rows[i] = new int[comps[i].W];
        bool ycc = colour.Count == 3 && space is ClrSycc or ClrEycc;
        var v = new int[4];
        for (int y = 0; y < height; y++)
        {
            for (int i = 0; i < count; i++)
            {
                int cy = Math.Clamp((int)((image.Y0 + y) / comps[i].Dy) - (int)comps[i].Y0, 0, (int)comps[i].H - 1);
                Marshal.Copy(comps[i].Data + (nint)((long)cy * comps[i].W * sizeof(int)), rows[i], 0, (int)comps[i].W);
            }
            int o = y * width * 4;
            for (int x = 0; x < width; x++, o += 4)
            {
                for (int k = 0; k < colour.Count; k++) v[k] = Sample(channels[colour[k]], palette, rows[colour[k]], luts[colour[k]], image.X0 + x);
                if (colour.Count == 1)
                {
                    rgba[o] = rgba[o + 1] = rgba[o + 2] = (byte)v[0];
                }
                else if (cmyk)
                {
                    int white = 255 - v[3];
                    for (int c = 0; c < 3; c++) rgba[o + c] = (byte)(((255 - v[c]) * white + 127) / 255);
                }
                else if (ycc)
                {
                    double yy = v[0], cb = v[1] - 128, cr = v[2] - 128;
                    rgba[o] = Clamp(yy + 1.402 * cr);
                    rgba[o + 1] = Clamp(yy - 0.344136 * cb - 0.714136 * cr);
                    rgba[o + 2] = Clamp(yy + 1.772 * cb);
                }
                else
                {
                    rgba[o] = (byte)v[0];
                    rgba[o + 1] = (byte)v[1];
                    rgba[o + 2] = (byte)v[2];
                }
                rgba[o + 3] = alpha < 0 ? (byte)255 : (byte)Sample(channels[alpha], palette, rows[alpha], luts[alpha], image.X0 + x);
                if (premultiplied && rgba[o + 3] is > 0 and < 255)
                {
                    for (int c = 0; c < 3; c++) rgba[o + c] = (byte)Math.Min(255, (rgba[o + c] * 255 + rgba[o + 3] / 2) / rgba[o + 3]);
                }
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }

    private static int Sample(Channel channel, Palette? palette, int[] row, byte[] lut, long x)
    {
        var c = channel.Comp;
        int cx = Math.Clamp((int)(x / c.Dx) - (int)c.X0, 0, row.Length - 1);
        long value = row[cx];
        if (channel.Mapped) value = palette!.Values[Math.Clamp(value, 0, palette.Entries - 1) * palette.Columns + channel.Column];
        if (channel.Signed) value += 1L << (channel.Prec - 1);
        return lut[Math.Clamp(value, 0, lut.Length - 1)];
    }

    // A sample of any depth as a byte, 0 to the depth's top mapped onto 0 to 255.
    private static byte[] Lut(int prec)
    {
        int top = (1 << prec) - 1;
        var lut = new byte[top + 1];
        for (int i = 0; i <= top; i++) lut[i] = (byte)((i * 255 + top / 2) / top);
        return lut;
    }

    private static byte Clamp(double value) => (byte)Math.Clamp((int)Math.Round(value), 0, 255);

    private sealed class Source(byte[] data)
    {
        private long position;

        public nuint Read(IntPtr buffer, nuint count, IntPtr user)
        {
            try
            {
                if (position >= data.Length) return nuint.MaxValue;
                int n = (int)Math.Min((long)count, data.Length - position);
                Marshal.Copy(data, (int)position, buffer, n);
                position += n;
                return (nuint)n;
            }
            catch (Exception)
            {
                return nuint.MaxValue;
            }
        }

        public long Skip(long count, IntPtr user)
        {
            long target = position + count;
            if (target < 0 || target > data.Length) return -1;
            position = target;
            return count;
        }

        public int Seek(long target, IntPtr user)
        {
            if (target < 0 || target > data.Length) return 0;
            position = target;
            return 1;
        }
    }
}
