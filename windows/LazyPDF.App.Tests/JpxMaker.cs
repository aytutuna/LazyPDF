using System.Runtime.InteropServices;

namespace LazyPDF.App.Tests;

// JPEG 2000 test files made with OpenJPEG's own encoder (reversible 5/3, so a round trip is exact).
internal static class JpxMaker
{
    public const int Unspecified = 0, Srgb = 1, Gray = 2, Sycc = 3, Cmyk = 5;

    // Offsets in opj_cparameters_t and opj_image_t on 64-bit Windows.
    private const int ParametersSize = 18800, DistoAlloc = 20, NumLayers = 4796, Rates = 4800, NumResolution = 5600, Irreversible = 5616, Mct = 18698;

    private delegate nuint WriteFn(IntPtr buffer, nuint count, IntPtr user);

    private delegate long SkipFn(long count, IntPtr user);

    private delegate int SeekFn(long position, IntPtr user);

    /// <summary>One component: its subsampling, depth and the w x h samples (w = ceil(width / dx)).</summary>
    public sealed record Comp(int Dx, int Dy, int Prec, bool Signed, int[] Samples, int Alpha = 0)
    {
        public Comp(int prec, int[] samples) : this(1, 1, prec, false, samples) { }
    }

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr opj_create_compress(int format);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_destroy_codec(IntPtr codec);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr opj_image_create(uint count, IntPtr parameters, int colorSpace);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_image_destroy(IntPtr image);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_set_default_encoder_parameters(IntPtr parameters);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_setup_encoder(IntPtr codec, IntPtr parameters, IntPtr image);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr opj_stream_create(nuint size, int input);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_destroy(IntPtr stream);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_write_function(IntPtr stream, WriteFn write);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_skip_function(IntPtr stream, SkipFn skip);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern void opj_stream_set_seek_function(IntPtr stream, SeekFn seek);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_start_compress(IntPtr codec, IntPtr image, IntPtr stream);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_encode(IntPtr codec, IntPtr stream);

    [DllImport("openjp2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int opj_end_compress(IntPtr codec, IntPtr stream);

    /// <summary>A codestream (<paramref name="jp2"/> false) or a JP2 file of the given components.</summary>
    public static byte[] Encode(int width, int height, int colorSpace, bool jp2, bool mct, params Comp[] comps) => Encode(width, height, 0, colorSpace, jp2, mct, comps);

    /// <summary>A codestream cut into tiles of <paramref name="tile"/> x <paramref name="tile"/> samples.</summary>
    public static byte[] Tiled(int width, int height, int tile, params Comp[] comps) => Encode(width, height, tile, Gray, false, false, comps);

    private static byte[] Encode(int width, int height, int tile, int colorSpace, bool jp2, bool mct, Comp[] comps)
    {
        var output = new MemoryStream();
        IntPtr parameters = Marshal.AllocHGlobal(ParametersSize), layout = Marshal.AllocHGlobal(comps.Length * 36);
        IntPtr codec = IntPtr.Zero, stream = IntPtr.Zero, image = IntPtr.Zero;
        WriteFn write = (buffer, count, _) =>
        {
            var bytes = new byte[(int)count];
            Marshal.Copy(buffer, bytes, 0, bytes.Length);
            output.Write(bytes);
            return count;
        };
        SkipFn skip = (count, _) =>
        {
            output.Seek(count, SeekOrigin.Current);
            return count;
        };
        SeekFn seek = (position, _) =>
        {
            output.Seek(position, SeekOrigin.Begin);
            return 1;
        };
        try
        {
            for (int i = 0; i < comps.Length; i++)
            {
                var c = comps[i];
                int w = (width + c.Dx - 1) / c.Dx, h = (height + c.Dy - 1) / c.Dy;
                Assert(c.Samples.Length == w * h);
                int[] fields = [c.Dx, c.Dy, w, h, 0, 0, c.Prec, 0, c.Signed ? 1 : 0];
                for (int f = 0; f < fields.Length; f++) Marshal.WriteInt32(layout, i * 36 + f * 4, fields[f]);
            }
            image = opj_image_create((uint)comps.Length, layout, colorSpace);
            Assert(image != IntPtr.Zero);
            Marshal.WriteInt32(image, 8, width);
            Marshal.WriteInt32(image, 12, height);
            IntPtr list = Marshal.ReadIntPtr(image, 24);
            for (int i = 0; i < comps.Length; i++)
            {
                IntPtr data = Marshal.ReadIntPtr(list, i * 64 + 48);
                Marshal.Copy(comps[i].Samples, 0, data, comps[i].Samples.Length);
                if (comps[i].Alpha != 0) Marshal.WriteInt16(list, i * 64 + 56, 1);
            }

            opj_set_default_encoder_parameters(parameters);
            if (tile > 0)
            {
                Marshal.WriteInt32(parameters, 0, 1);
                Marshal.WriteInt32(parameters, 12, tile);
                Marshal.WriteInt32(parameters, 16, tile);
            }
            Marshal.WriteInt32(parameters, DistoAlloc, 1);
            Marshal.WriteInt32(parameters, NumLayers, 1);
            Marshal.WriteInt32(parameters, Rates, 0);
            Marshal.WriteInt32(parameters, NumResolution, 3);
            Marshal.WriteInt32(parameters, Irreversible, 0);
            Marshal.WriteByte(parameters, Mct, mct ? (byte)1 : (byte)0);

            codec = opj_create_compress(jp2 ? 2 : 0);
            Assert(opj_setup_encoder(codec, parameters, image) != 0);
            stream = opj_stream_create(1 << 16, 0);
            opj_stream_set_write_function(stream, write);
            opj_stream_set_skip_function(stream, skip);
            opj_stream_set_seek_function(stream, seek);
            Assert(opj_start_compress(codec, image, stream) != 0);
            Assert(opj_encode(codec, stream) != 0);
            Assert(opj_end_compress(codec, stream) != 0);
            return output.ToArray();
        }
        finally
        {
            if (codec != IntPtr.Zero) opj_destroy_codec(codec);
            if (stream != IntPtr.Zero) opj_stream_destroy(stream);
            if (image != IntPtr.Zero) opj_image_destroy(image);
            Marshal.FreeHGlobal(parameters);
            Marshal.FreeHGlobal(layout);
            GC.KeepAlive(write);
            GC.KeepAlive(skip);
            GC.KeepAlive(seek);
        }
    }

    /// <summary>A JP2 file whose one 8-bit component is indices into an RGB palette.</summary>
    public static byte[] Paletted(int width, int height, int[] indices, byte[][] palette)
    {
        var pclr = new List<byte> { (byte)(palette.Length >> 8), (byte)palette.Length, 3, 7, 7, 7 };
        foreach (var entry in palette) pclr.AddRange(entry);
        byte[] code = Encode(width, height, Unspecified, false, false, new Comp(8, indices));
        return Wrap(width, height, 1, code, ("colr", [1, 0, 0, .. Be(16)]), ("pclr", [.. pclr]), ("cmap", [0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 2]));
    }

    /// <summary>A codestream in a JP2 file with the given boxes in its header, after the image header.</summary>
    public static byte[] Wrap(int width, int height, int components, byte[] code, params (string Type, byte[] Content)[] boxes)
    {
        var file = new MemoryStream();
        Box(file, "jP  ", [0x0D, 0x0A, 0x87, 0x0A]);
        Box(file, "ftyp", [.. "jp2 "u8, 0, 0, 0, 0, .. "jp2 "u8]);

        var header = new MemoryStream();
        Box(header, "ihdr", [.. Be(height), .. Be(width), (byte)(components >> 8), (byte)components, 7, 7, 0, 0]);
        foreach (var (type, content) in boxes) Box(header, type, content);
        Box(file, "jp2h", header.ToArray());

        Box(file, "jp2c", code);
        return file.ToArray();
    }

    /// <summary>Boxes of a header, one after the other.</summary>
    public static byte[] Boxes(params (string Type, byte[] Content)[] boxes)
    {
        var all = new MemoryStream();
        foreach (var (type, content) in boxes) Box(all, type, content);
        return all.ToArray();
    }

    /// <summary>A file made by <see cref="Wrap"/> with a box of its own put in front of the codestream box.</summary>
    public static byte[] Before(byte[] file, int codeLength, string type, byte[] content)
    {
        int at = file.Length - 8 - codeLength;
        return [.. file[..at], .. Boxes((type, content)), .. file[at..]];
    }

    /// <summary>A channel definition box: for each channel its type and association.</summary>
    public static (string, byte[]) Cdef(params (int Type, int Association)[] channels)
    {
        var content = new List<byte> { (byte)(channels.Length >> 8), (byte)channels.Length };
        for (int i = 0; i < channels.Length; i++)
        {
            content.AddRange([(byte)(i >> 8), (byte)i, (byte)(channels[i].Type >> 8), (byte)channels[i].Type, (byte)(channels[i].Association >> 8), (byte)channels[i].Association]);
        }
        return ("cdef", [.. content]);
    }

    public static (string, byte[]) Colr(int enumerated) => ("colr", [1, 0, 0, .. Be(enumerated)]);

    private static byte[] Be(int value) => [(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value];

    private static void Box(MemoryStream to, string type, byte[] content)
    {
        to.Write(Be(8 + content.Length));
        to.Write(System.Text.Encoding.ASCII.GetBytes(type));
        to.Write(content);
    }

    private static void Assert(bool condition)
    {
        if (!condition) throw new InvalidOperationException("OpenJPEG could not make the test file.");
    }
}
