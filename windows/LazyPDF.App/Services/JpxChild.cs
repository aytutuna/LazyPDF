using System.Runtime.InteropServices;

namespace LazyPDF.App.Services;

/// <summary>
/// The decode mode of the app (<c>--decode-jpx</c>): reads requests from stdin and answers on stdout until stdin closes.
/// A request is a byte for what to do (<see cref="Decode"/> for a picture), a little-endian int for the colour space's
/// component count, an int for the length of the file and the file. A reply is a status byte, 0 with the width, height and
/// RGBA bytes, 1 when the picture cannot be read. Right after it starts the child writes one byte, <see cref="Ready"/>.
/// </summary>
internal static class JpxChild
{
    public const string Switch = "--decode-jpx";
    public const byte Decode = 0, Ready = 0x52;

    // Tests only: what a hostile file could do to the process. They are reachable by whoever writes to the pipe, who owns the process anyway.
    public const byte Crash = 1, Hang = 2, Allocate = 3;

    // The child has no message loop; one call tells Windows it is up, so the busy cursor does not follow every start.
    [DllImport("user32")]
    private static extern bool PeekMessageW(byte[] message, IntPtr window, uint min, uint max, uint remove);

    public static int Run()
    {
        PeekMessageW(new byte[48], IntPtr.Zero, 0, 0, 0);
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        output.WriteByte(Ready);
        output.Flush();
        var head = new byte[9];
        while (input.ReadAtLeast(head, head.Length, false) == head.Length)
        {
            int hint = BitConverter.ToInt32(head, 1), length = BitConverter.ToInt32(head, 5);
            if (length < 0) return 2;
            switch (head[0])
            {
                case Crash:
                    Environment.Exit(3);
                    break;
                case Hang:
                    Thread.Sleep(Timeout.Infinite);
                    break;
                case Allocate:
                    // hint is megabytes, written to so that they are committed.
                    Array.Fill(new byte[(long)hint << 20], (byte)1);
                    break;
            }
            var data = new byte[length];
            if (input.ReadAtLeast(data, length, false) < length) return 2;
            var image = head[0] == Decode ? OpenJpeg.DecodeHere(data, hint) : null;
            if (image is null)
            {
                output.WriteByte(1);
            }
            else
            {
                output.WriteByte(0);
                output.Write(BitConverter.GetBytes(image.Width));
                output.Write(BitConverter.GetBytes(image.Height));
                output.Write(image.Rgba);
            }
            output.Flush();
        }
        return 0;
    }
}
