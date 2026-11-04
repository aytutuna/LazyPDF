using System.Text;

namespace LazyPDF.Core.Tests;

internal static class FilterFixtures
{
    public static PdfObject Parse(string text) =>
        new PdfLexer(new PdfArrayBytes(Encoding.Latin1.GetBytes(text))).ReadObject();

    public static PdfDictionary Dict(string text) => (PdfDictionary)Parse(text);

    public static PdfObject? Resolve(PdfObject? value) => value;

    /// <summary>Streams made for a test with the data a decoder would give back for them.</summary>
    public sealed class Streams
    {
        private readonly Dictionary<PdfStream, byte[]> _data = [];

        public PdfStream Add(string dictionary, byte[] data)
        {
            var stream = new PdfStream(Dict(dictionary), 0);
            _data[stream] = data;
            return stream;
        }

        public byte[] Decode(PdfStream stream) => _data[stream];
    }

    public static byte[] RandomBytes(int length, int seed = 1)
    {
        var bytes = new byte[length];
        new Random(seed).NextBytes(bytes);
        return bytes;
    }

    /// <summary>Bytes that compress and still vary.</summary>
    public static byte[] Text(int length)
    {
        var bytes = new byte[length];
        var random = new Random(7);
        for (int i = 0; i < length; i++) bytes[i] = (byte)('a' + random.Next(6));
        return bytes;
    }
}
