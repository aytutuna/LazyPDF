using System.Reflection;
using System.Runtime.InteropServices;
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

    /// <summary>A JPEG 2000 file or codestream as RGBA, or null when it cannot be read or is over the pixel cap.</summary>
    public static PdfRgbaImage? Decode(byte[] data)
    {
        int format = Format(data);
        if (format < 0) return null;
        IntPtr parameters = IntPtr.Zero, codec = IntPtr.Zero, stream = IntPtr.Zero, image = IntPtr.Zero;
        var source = new Source(data);
        ReadFn read = source.Read;
        SkipFn skip = source.Skip;
        SeekFn seek = source.Seek;
        try
        {
            parameters = Marshal.AllocHGlobal(DecoderParametersSize);
            opj_set_default_decoder_parameters(parameters);
            codec = opj_create_decompress(format);
            if (codec == IntPtr.Zero) return null;
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

            if (opj_decode(codec, stream, image) == 0 || opj_end_decompress(codec, stream) == 0) return null;
            return ToRgba(Marshal.PtrToStructure<Image>(image), (int)width, (int)height);
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

    private static PdfRgbaImage? ToRgba(Image image, int width, int height)
    {
        int count = (int)image.NumComps;
        var comps = new Component[count];
        for (int i = 0; i < count; i++)
        {
            comps[i] = Marshal.PtrToStructure<Component>(image.Comps + i * Marshal.SizeOf<Component>());
            ref var c = ref comps[i];
            if (c.Data == IntPtr.Zero || c.Dx < 1 || c.Dy < 1 || c.W < 1 || c.H < 1 || c.Prec is < 1 or > 16) return null;
            if (c.W > (width + c.Dx - 1) / c.Dx + 1 || c.H > (height + c.Dy - 1) / c.Dy + 1) return null;
        }

        int space = image.ColorSpace;
        // A YCC picture is the one whose chroma is subsampled, whatever the header says.
        if (count == 3 && space is not (ClrSycc or ClrEycc) && comps[0].Dx == comps[0].Dy && comps[1].Dx != 1) space = ClrSycc;

        var alphas = Enumerable.Range(0, count).Where(i => comps[i].Alpha != 0).ToList();
        int alpha = alphas.Count > 0 ? alphas[0] : -1;
        var colour = Enumerable.Range(0, count).Where(i => !alphas.Contains(i)).ToList();
        if (alpha < 0)
        {
            bool known = space is ClrGray or ClrSrgb or ClrSycc or ClrEycc;
            if (count == 2 || known && count is 2 or 4) alpha = count - 1;
            if (alpha >= 0) colour.Remove(alpha);
        }
        if (colour.Count is 2) colour.RemoveAt(1);
        if (colour.Count is not (1 or 3 or 4)) return null;
        bool cmyk = colour.Count == 4;

        var luts = new byte[count][];
        for (int i = 0; i < count; i++) luts[i] = Lut(comps[i]);

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
                for (int k = 0; k < colour.Count; k++) v[k] = Sample(comps[colour[k]], rows[colour[k]], luts[colour[k]], image.X0 + x);
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
                rgba[o + 3] = alpha < 0 ? (byte)255 : (byte)Sample(comps[alpha], rows[alpha], luts[alpha], image.X0 + x);
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }

    private static int Sample(Component c, int[] row, byte[] lut, long x)
    {
        int cx = Math.Clamp((int)(x / c.Dx) - (int)c.X0, 0, row.Length - 1);
        long value = row[cx];
        if (c.Sgnd != 0) value += 1L << (int)(c.Prec - 1);
        return lut[Math.Clamp(value, 0, lut.Length - 1)];
    }

    // A sample of any depth as a byte, 0 to the depth's top mapped onto 0 to 255.
    private static byte[] Lut(Component c)
    {
        int top = (1 << (int)c.Prec) - 1;
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
