namespace LazyPDF.Core;

// From Lazy Scan's PdfSyntax.cs: what a lexer reads, and the exception a file it cannot use raises.

/// <summary>The bytes a lexer reads: a whole array, or a seekable file read in blocks as needed.</summary>
public abstract class PdfBytes
{
    public abstract long Length { get; }

    /// <summary>The byte at <paramref name="position"/>; -1 past the end.</summary>
    public abstract int this[long position] { get; }

    /// <summary>Up to <paramref name="count"/> bytes from <paramref name="position"/> (fewer at the end).</summary>
    public abstract byte[] Read(long position, int count);
}

public sealed class PdfArrayBytes(byte[] bytes) : PdfBytes
{
    private readonly byte[] _bytes = bytes;
    public override long Length => _bytes.Length;
    public override int this[long position] => position >= 0 && position < _bytes.Length ? _bytes[position] : -1;

    public override byte[] Read(long position, int count)
    {
        if (position < 0 || position >= _bytes.Length || count <= 0) return [];
        int n = (int)Math.Min(count, _bytes.Length - position);
        return _bytes.AsSpan((int)position, n).ToArray();
    }
}

/// <summary>A seekable stream read through a few cached 64 KB blocks, so a large file is never read whole.</summary>
public sealed class PdfStreamBytes : PdfBytes
{
    private const int BlockSize = 1 << 16;
    private const int CachedBlocks = 16;
    private readonly Stream _stream;
    private readonly Dictionary<long, byte[]> _blocks = [];
    private readonly LinkedList<long> _recent = new();

    public PdfStreamBytes(Stream stream)
    {
        if (!stream.CanSeek || !stream.CanRead) throw new ArgumentException("The PDF must be read from a seekable stream.", nameof(stream));
        _stream = stream;
        Length = stream.Length;
    }

    public override long Length { get; }

    public override int this[long position]
    {
        get
        {
            if (position < 0 || position >= Length) return -1;
            var block = Block(position / BlockSize);
            int index = (int)(position % BlockSize);
            return index < block.Length ? block[index] : -1;
        }
    }

    public override byte[] Read(long position, int count)
    {
        if (position < 0 || position >= Length || count <= 0) return [];
        int n = (int)Math.Min(count, Length - position);
        var result = new byte[n];
        int done = 0;
        while (done < n)
        {
            long at = position + done;
            var block = Block(at / BlockSize);
            int index = (int)(at % BlockSize);
            if (index >= block.Length) break;
            int take = Math.Min(n - done, block.Length - index);
            Buffer.BlockCopy(block, index, result, done, take);
            done += take;
        }
        return done == n ? result : result[..done];
    }

    private byte[] Block(long number)
    {
        if (_blocks.TryGetValue(number, out var cached))
        {
            _recent.Remove(number);
            _recent.AddFirst(number);
            return cached;
        }
        long start = number * BlockSize;
        int size = (int)Math.Min(BlockSize, Length - start);
        var block = new byte[Math.Max(size, 0)];
        _stream.Position = start;
        _stream.ReadExactly(block);
        _blocks[number] = block;
        _recent.AddFirst(number);
        if (_recent.Count > CachedBlocks)
        {
            _blocks.Remove(_recent.Last!.Value);
            _recent.RemoveLast();
        }
        return block;
    }
}

/// <summary>A file the reader cannot use: what is wrong, for the message the user sees.</summary>
public enum PdfReadProblem
{
    /// <summary>Not a PDF at all (no "%PDF-" header).</summary>
    NotPdf,
    /// <summary>The cross-reference data or an object is not where or what it should be.</summary>
    Damaged,
    /// <summary>The file is encrypted (it has an /Encrypt dictionary).</summary>
    Encrypted,
    /// <summary>The file is encrypted and the password given does not open it.</summary>
    PasswordRequired,
    /// <summary>The file uses something this reader does not handle (a filter other than Flate, say).</summary>
    Unsupported,
    /// <summary>The file is encrypted for recipients and the certificate given, if any, is not one of them or has no private key.</summary>
    CertificateRequired,
}

/// <summary>Thrown by <see cref="PdfDocument"/>; the message is technical, <see cref="Problem"/> says what kind.</summary>
public sealed class PdfReadException(PdfReadProblem problem, string detail) : Exception(detail)
{
    public PdfReadProblem Problem { get; } = problem;

    public static PdfReadException Damaged(string detail) => new(PdfReadProblem.Damaged, detail);
}
