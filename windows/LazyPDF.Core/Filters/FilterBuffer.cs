namespace LazyPDF.Core;

/// <summary>Output of a decoder: grows on demand and throws once it passes the size cap.</summary>
internal sealed class FilterBuffer(long max, int capacity = 0)
{
    private byte[] _bytes = new byte[Math.Clamp(capacity, 256, 1 << 22)];
    private int _count;

    public int Count => _count;

    public static PdfReadException TooBig() =>
        new(PdfReadProblem.Unsupported, "A stream expands past the size limit.");

    public void Add(byte value)
    {
        if (_count >= max) throw TooBig();
        if (_count == _bytes.Length) Grow(_count + 1L);
        _bytes[_count++] = value;
    }

    public void Add(ReadOnlySpan<byte> values)
    {
        values.CopyTo(Append(values.Length));
    }

    /// <summary>Counts <paramref name="length"/> more bytes and returns them for the caller to fill.</summary>
    public Span<byte> Append(int length)
    {
        if (_count + (long)length > max) throw TooBig();
        if (_count + (long)length > _bytes.Length) Grow(_count + (long)length);
        var span = _bytes.AsSpan(_count, length);
        _count += length;
        return span;
    }

    /// <summary>Room for up to <paramref name="length"/> bytes past the end, one more than the cap allows; <see cref="Commit"/> what was written.</summary>
    public Span<byte> Reserve(int length)
    {
        int room = (int)Math.Min(length, max + 1 - _count);
        if (_count + (long)room > _bytes.Length) Grow(_count + (long)room);
        return _bytes.AsSpan(_count, room);
    }

    public void Commit(int length)
    {
        _count += length;
        if (_count > max) throw TooBig();
    }

    // Callers discard the buffer, so a full one is handed over without a copy.
    public byte[] ToArray() => _count == _bytes.Length ? _bytes : _bytes.AsSpan(0, _count).ToArray();

    private void Grow(long needed)
    {
        long size = Math.Min(Math.Max(needed, _bytes.Length * 2L), Math.Min(max + 1, Array.MaxLength));
        if (size < needed) throw TooBig();
        Array.Resize(ref _bytes, (int)size);
    }
}
