using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's PdfSyntax.cs, made more forgiving: numbers, unclosed arrays and dictionaries,
// stray keys and stray hex digits read as a viewer would read them.

/// <summary>
/// Tokens and objects from PDF bytes (ISO 32000-1 7.2, 7.3): white space and comments skipped,
/// names with #xx escapes, literal strings with their escapes and nested parentheses, hex
/// strings, numbers, "n g R" references, arrays, dictionaries and the start of a stream's data.
/// </summary>
public sealed class PdfLexer(PdfBytes bytes, long position = 0)
{
    /// <summary>Deeper nesting than this is refused rather than risking the stack.</summary>
    private const int MaxDepth = 200;

    public PdfBytes Bytes { get; } = bytes;
    public long Position { get; set; } = position;

    public static bool IsWhiteSpace(int b) => b is 0 or 9 or 10 or 12 or 13 or 32;

    public static bool IsDelimiter(int b) => b is '(' or ')' or '<' or '>' or '[' or ']' or '{' or '}' or '/' or '%';

    private static bool IsRegular(int b) => b >= 0 && !IsWhiteSpace(b) && !IsDelimiter(b);

    private int Peek(long offset = 0) => Bytes[Position + offset];

    /// <summary>Skips white space and comments.</summary>
    public void SkipWhiteSpace()
    {
        while (true)
        {
            int b = Peek();
            if (IsWhiteSpace(b))
            {
                Position++;
            }
            else if (b == '%')
            {
                while (Peek() is not (-1 or 10 or 13)) Position++;
            }
            else
            {
                return;
            }
        }
    }

    /// <summary>The next run of regular characters ("obj", "123", "true"); empty at a delimiter or the end.</summary>
    public string ReadKeyword()
    {
        SkipWhiteSpace();
        var sb = new StringBuilder();
        while (IsRegular(Peek()))
        {
            sb.Append((char)Peek());
            Position++;
        }
        return sb.ToString();
    }

    /// <summary>A non-negative integer token, or null (the position is then where it was).</summary>
    public long? TryReadUnsigned()
    {
        long start = Position;
        SkipWhiteSpace();
        long value = 0;
        int digits = 0;
        while (Peek() is >= '0' and <= '9')
        {
            if (value > (long.MaxValue - 9) / 10) { Position = start; return null; }
            value = value * 10 + (Peek() - '0');
            Position++;
            digits++;
        }
        if (digits == 0 || IsRegular(Peek()))
        {
            Position = start;
            return null;
        }
        return value;
    }

    /// <summary>"n g obj" at the current position; the object's number and generation.</summary>
    public (int Number, int Generation) ReadObjectHeader()
    {
        long? number = TryReadUnsigned();
        long? generation = number is null ? null : TryReadUnsigned();
        if (number is null || generation is null || number > int.MaxValue || generation > 65535 || ReadKeyword() != "obj")
        {
            throw PdfReadException.Damaged($"No object header at byte {Position}.");
        }
        return ((int)number.Value, (int)generation.Value);
    }

    /// <summary>
    /// One object; a dictionary followed by "stream" becomes a <see cref="PdfStream"/> whose data
    /// starts after the keyword's end of line.
    /// </summary>
    public PdfObject ReadObject(bool allowStream = true) => ReadObject(0, allowStream);

    private PdfObject ReadObject(int depth, bool allowStream)
    {
        if (depth > MaxDepth) throw new PdfReadException(PdfReadProblem.Unsupported, "Objects are nested too deeply.");
        SkipWhiteSpace();
        int b = Peek();
        switch (b)
        {
            case -1:
                throw PdfReadException.Damaged("The file ends inside an object.");
            case '/':
                Position++;
                return new PdfName(ReadNameBody());
            case '(':
                Position++;
                return new PdfString(ReadLiteralBody(), isHex: false);
            case '[':
            {
                Position++;
                var items = new List<PdfObject>();
                while (true)
                {
                    SkipWhiteSpace();
                    if (Peek() == ']') { Position++; break; }
                    if (Peek() == -1) throw PdfReadException.Damaged("An array is not closed.");
                    if (AtObjectEnd()) break; // a missing ] is made up for
                    items.Add(ReadObject(depth + 1, allowStream: false));
                }
                return new PdfArray(items);
            }
            case '<' when Peek(1) == '<':
            {
                Position += 2;
                var dictionary = new PdfDictionary();
                while (true)
                {
                    SkipWhiteSpace();
                    if (Peek() == '>' && Peek(1) == '>') { Position += 2; break; }
                    if (AtObjectEnd()) break; // so is a missing >>
                    if (Peek() == -1) throw PdfReadException.Damaged("A dictionary is not closed.");
                    if (Peek() != '/')
                    {
                        // Something that is not a key (seen in the wild): read past it.
                        ReadObject(depth + 1, allowStream: false);
                        continue;
                    }
                    Position++;
                    string key = ReadNameBody();
                    SkipWhiteSpace();
                    // A key without a value before the end (seen in the wild) reads as null.
                    PdfObject value = Peek() == '>' && Peek(1) == '>' ? PdfNull.Instance : ReadObject(depth + 1, allowStream: false);
                    dictionary.Add(key, value);
                }
                if (allowStream && AtStreamKeyword(out long dataStart)) return new PdfStream(dictionary, dataStart);
                return dictionary;
            }
            case '<':
                Position++;
                return new PdfString(ReadHexBody(), isHex: true);
        }
        if (b is (>= '0' and <= '9') or '+' or '-' or '.')
        {
            string number = ReadKeyword();
            if (!IsNumber(number)) number = Normalize(number);
            // "n g R": an integer, another, then R.
            if (number.All(char.IsAsciiDigit))
            {
                long save = Position;
                long? generation = TryReadUnsigned();
                if (generation is not null && ReadKeyword() == "R" && int.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out int n) && generation <= 65535)
                {
                    return new PdfReference(n, (int)generation.Value);
                }
                Position = save;
            }
            return new PdfNumber(number);
        }
        string keyword = ReadKeyword();
        return keyword switch
        {
            "true" => new PdfBoolean(true),
            "false" => new PdfBoolean(false),
            "null" => PdfNull.Instance,
            "" => throw PdfReadException.Damaged($"Unexpected '{(char)b}' at byte {Position}."),
            _ => throw PdfReadException.Damaged($"Unexpected \"{keyword}\" at byte {Position}."),
        };
    }

    private static bool IsNumber(string text)
    {
        if (text.Length == 0) return false;
        int i = text[0] is '+' or '-' ? 1 : 0;
        bool digits = false, dot = false;
        for (; i < text.Length; i++)
        {
            if (char.IsAsciiDigit(text[i])) digits = true;
            else if (text[i] == '.' && !dot) dot = true;
            else return false;
        }
        return digits;
    }

    /// <summary>The number a token means when it is not quite one ("--5", "1.2.3", "5-3"): its sign, digits and first point.</summary>
    private static string Normalize(string token)
    {
        int i = 0;
        while (i < token.Length && token[i] is '+' or '-') i++;
        var sb = new StringBuilder();
        if (i > 0 && token[0] == '-') sb.Append('-');
        bool dot = false;
        for (; i < token.Length; i++)
        {
            if (token[i] == '.' && !dot) dot = true;
            else if (!char.IsAsciiDigit(token[i])) break;
            sb.Append(token[i]);
        }
        string text = sb.ToString();
        return text.Any(char.IsAsciiDigit) ? text : "0";
    }

    /// <summary>At "endobj" or "endstream": where an array or dictionary that was never closed has to stop.</summary>
    private bool AtObjectEnd() => Peek() == 'e' && (AtWord("endobj") || AtWord("endstream"));

    private bool AtWord(string word)
    {
        for (int i = 0; i < word.Length; i++)
        {
            if (Peek(i) != word[i]) return false;
        }
        return !IsRegular(Peek(word.Length));
    }

    /// <summary>After a dictionary: "stream" and its end of line (CRLF or LF; a lone CR is tolerated).</summary>
    private bool AtStreamKeyword(out long dataStart)
    {
        dataStart = 0;
        long save = Position;
        SkipWhiteSpace();
        if (ReadKeyword() != "stream")
        {
            Position = save;
            return false;
        }
        // Spaces between the keyword and its line break are not data.
        long spaces = 0;
        while (Peek(spaces) is 32 or 9) spaces++;
        if (Peek(spaces) is 10 or 13) Position += spaces;
        if (Peek() == 13 && Peek(1) == 10) Position += 2;
        else if (Peek() is 10 or 13) Position++;
        dataStart = Position;
        return true;
    }

    private string ReadNameBody()
    {
        var sb = new StringBuilder();
        while (IsRegular(Peek()))
        {
            int c = Peek();
            if (c == '#' && HexValue(Peek(1)) is int high && HexValue(Peek(2)) is int low)
            {
                sb.Append((char)(high * 16 + low));
                Position += 3;
                continue;
            }
            sb.Append((char)c);
            Position++;
        }
        return sb.ToString();
    }

    private byte[] ReadLiteralBody()
    {
        var bytes = new List<byte>();
        int depth = 1;
        while (true)
        {
            int c = Peek();
            if (c == -1) throw PdfReadException.Damaged("A string is not closed.");
            Position++;
            if (c == '\\')
            {
                int e = Peek();
                if (e == -1) throw PdfReadException.Damaged("A string is not closed.");
                Position++;
                switch (e)
                {
                    case 'n': bytes.Add(10); break;
                    case 'r': bytes.Add(13); break;
                    case 't': bytes.Add(9); break;
                    case 'b': bytes.Add(8); break;
                    case 'f': bytes.Add(12); break;
                    case 13:
                        if (Peek() == 10) Position++; // a line continued: nothing
                        break;
                    case 10:
                        break;
                    case >= '0' and <= '7':
                    {
                        int value = e - '0';
                        for (int k = 0; k < 2 && Peek() is >= '0' and <= '7'; k++)
                        {
                            value = value * 8 + (Peek() - '0');
                            Position++;
                        }
                        bytes.Add((byte)value);
                        break;
                    }
                    default:
                        bytes.Add((byte)e); // \( \) \\ and any other character stand for themselves
                        break;
                }
                continue;
            }
            if (c == '(') depth++;
            if (c == ')' && --depth == 0) break;
            // An end of line inside a string reads as LF (7.3.4.2).
            if (c == 13)
            {
                if (Peek() == 10) Position++;
                bytes.Add(10);
                continue;
            }
            bytes.Add((byte)c);
        }
        return [.. bytes];
    }

    private byte[] ReadHexBody()
    {
        var bytes = new List<byte>();
        int? high = null;
        while (true)
        {
            int c = Peek();
            if (c == -1) throw PdfReadException.Damaged("A hex string is not closed.");
            Position++;
            if (c == '>') break;
            if (IsWhiteSpace(c)) continue;
            if (HexValue(c) is not int digit) continue; // stray characters are ignored
            if (high is int h)
            {
                bytes.Add((byte)(h * 16 + digit));
                high = null;
            }
            else
            {
                high = digit;
            }
        }
        if (high is int last) bytes.Add((byte)(last * 16)); // an odd last digit is followed by 0
        return [.. bytes];
    }

    private static int? HexValue(int c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'A' and <= 'F' => c - 'A' + 10,
        >= 'a' and <= 'f' => c - 'a' + 10,
        _ => null,
    };
}
