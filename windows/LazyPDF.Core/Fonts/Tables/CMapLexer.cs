namespace LazyPDF.Core;

// Tokens of a CMap file. A hex string is decoded into a small buffer and cut off at its size: a
// destination string longer than that is not text a font maps one code to.
internal ref struct CMapLexer
{
    public enum Kind { End, Name, Hex, Number, Word, ArrayOpen, ArrayClose, Other }

    const int HexCapacity = 256;

    readonly ReadOnlySpan<byte> _data;
    readonly byte[] _hex = new byte[HexCapacity];
    int _at;
    int _textStart, _textLength, _hexLength;

    public CMapLexer(ReadOnlySpan<byte> data) => _data = data;

    public long Number { get; private set; }

    /// <summary>The name (without the slash) or the word last read.</summary>
    public readonly ReadOnlySpan<byte> Text => _data.Slice(_textStart, _textLength);

    public Kind Next()
    {
        SkipSpace();
        if (_at >= _data.Length)
            return Kind.End;
        byte c = _data[_at];
        switch (c)
        {
            case (byte)'/':
                _at++;
                Regular();
                return Kind.Name;
            case (byte)'<' when _at + 1 < _data.Length && _data[_at + 1] == '<':
            case (byte)'>' when _at + 1 < _data.Length && _data[_at + 1] == '>':
                _at += 2;
                return Kind.Other;
            case (byte)'<':
                _at++;
                ReadHex();
                return Kind.Hex;
            case (byte)'[':
                _at++;
                return Kind.ArrayOpen;
            case (byte)']':
                _at++;
                return Kind.ArrayClose;
            case (byte)'(':
                SkipString();
                return Kind.Other;
            case (byte)'>' or (byte)')' or (byte)'{' or (byte)'}':
                _at++;
                return Kind.Other;
        }
        Regular();
        return TryNumber() ? Kind.Number : Kind.Word;
    }

    /// <summary>The bytes of a code in a hex string as a number; false when it is empty or longer than four bytes.</summary>
    public readonly bool Code(out uint code, out int length)
    {
        code = 0;
        length = _hexLength;
        if (_hexLength is < 1 or > 4)
            return false;
        for (int i = 0; i < _hexLength; i++)
            code = (code << 8) | _hex[i];
        return true;
    }

    /// <summary>The hex string as UTF-16BE text (ISO 32000-1 9.10.3); a single byte stands for the character of that value.</summary>
    public readonly string Utf16()
    {
        int length = Math.Min(_hexLength, HexCapacity);
        if (length == 1)
            return ((char)_hex[0]).ToString();
        var chars = new char[length / 2];
        for (int i = 0; i < chars.Length; i++)
            chars[i] = (char)((_hex[2 * i] << 8) | _hex[2 * i + 1]);
        return new string(chars);
    }

    void SkipSpace()
    {
        while (_at < _data.Length)
        {
            byte c = _data[_at];
            if (c == '%')
            {
                while (_at < _data.Length && _data[_at] is not ((byte)'\n' or (byte)'\r'))
                    _at++;
            }
            else if (IsSpace(c))
                _at++;
            else
                return;
        }
    }

    void Regular()
    {
        _textStart = _at;
        while (_at < _data.Length && !IsSpace(_data[_at]) && !IsDelimiter(_data[_at]))
            _at++;
        _textLength = _at - _textStart;
    }

    bool TryNumber()
    {
        var t = Text;
        int i = t[0] is (byte)'-' or (byte)'+' ? 1 : 0;
        if (i == t.Length || t.Length - i > 18)
            return false;
        long value = 0;
        for (int j = i; j < t.Length; j++)
        {
            if (t[j] is < (byte)'0' or > (byte)'9')
                return false;
            value = value * 10 + (t[j] - '0');
        }
        Number = t[0] == '-' ? -value : value;
        return true;
    }

    void ReadHex()
    {
        _hexLength = 0;
        int half = -1;
        while (_at < _data.Length)
        {
            byte c = _data[_at++];
            if (c == '>')
                break;
            int digit = HexValue(c);
            if (digit < 0)
                continue;
            if (half < 0)
                half = digit;
            else
            {
                Store((half << 4) | digit);
                half = -1;
            }
        }
        if (half >= 0)
            Store(half << 4);
    }

    // Past the buffer the length keeps counting, so a caller can tell the string was cut off.
    void Store(int value)
    {
        if (_hexLength < HexCapacity)
            _hex[_hexLength] = (byte)value;
        if (_hexLength < int.MaxValue)
            _hexLength++;
    }

    void SkipString()
    {
        int depth = 0;
        while (_at < _data.Length)
        {
            byte c = _data[_at++];
            if (c == '\\')
                _at++;
            else if (c == '(')
                depth++;
            else if (c == ')' && --depth == 0)
                return;
        }
    }

    static int HexValue(byte c) => c switch
    {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        _ => -1,
    };

    static bool IsSpace(byte c) => c is 0 or 9 or 10 or 12 or 13 or 32;

    static bool IsDelimiter(byte c) => c is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']'
        or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';
}
