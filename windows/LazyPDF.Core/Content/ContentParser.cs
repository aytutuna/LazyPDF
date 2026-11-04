using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Content stream bytes to operations (ISO 32000-1 7.8.2, Annex A). Nothing in the data stops the
/// parse: unknown operators come back as they are, stray delimiters and unclosed arrays are made
/// up for, and the work is linear in the length.
/// </summary>
public static class ContentParser
{
    // Operands kept for one operator; the rest are dropped. Real operators take at most a few dozen.
    private const int MaxOperands = 512;
    private const int MaxDepth = 64;
    private const int MaxOperatorLength = 32;

    private static readonly Dictionary<string, string> Known = BuildKnown();

    public static IReadOnlyList<ContentOperation> Parse(byte[] data) => new Scanner(data, int.MaxValue).Run();

    /// <summary>As above; more than <paramref name="maxOperations"/> operations is a <see cref="PdfReadException"/>.</summary>
    internal static IReadOnlyList<ContentOperation> Parse(byte[] data, int maxOperations) => new Scanner(data, maxOperations).Run();

    private static Dictionary<string, string> BuildKnown()
    {
        string[] names =
        [
            "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP",
            "EI", "EMC", "ET", "EX", "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M",
            "MP", "n", "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td",
            "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w", "W", "W*", "y", "'", "\"",
        ];
        return names.ToDictionary(n => n);
    }

    private static bool IsWhite(int c) => c is 0 or 9 or 10 or 12 or 13 or 32;

    private static bool IsDelimiter(int c) => c is '(' or ')' or '<' or '>' or '[' or ']' or '{' or '}' or '/' or '%';

    private static bool IsRegular(int c) => !IsWhite(c) && !IsDelimiter(c);

    private static int Hex(int c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'A' and <= 'F' => c - 'A' + 10,
        >= 'a' and <= 'f' => c - 'a' + 10,
        _ => -1,
    };

    private sealed class Scanner(byte[] d, int maxOperations)
    {
        private readonly List<byte> _text = [];
        private readonly Dictionary<string, string>.AlternateLookup<ReadOnlySpan<char>> _known = Known.GetAlternateLookup<ReadOnlySpan<char>>();
        private int _p;

        public List<ContentOperation> Run()
        {
            var ops = new List<ContentOperation>();
            var operands = new List<PdfObject>();
            int opStart = 0;
            while (true)
            {
                SkipSpace();
                if (_p >= d.Length) break;
                if (ops.Count > maxOperations) throw PdfReadException.Damaged("Too many operations in a content stream.");
                if (operands.Count == 0) opStart = _p;
                var value = ReadValue(0);
                if (value is not null)
                {
                    if (operands.Count < MaxOperands) operands.Add(value);
                    continue;
                }
                if (IsDelimiter(d[_p]))
                {
                    _p++;
                    continue;
                }
                string name = ReadWord();
                if (name == "BI")
                {
                    var image = ReadInlineImage();
                    ops.Add(new ContentOperation("BI", [], opStart, _p, image));
                }
                else
                {
                    ops.Add(new ContentOperation(name, operands.Count == 0 ? [] : [.. operands], opStart, _p));
                }
                operands.Clear();
            }
            return ops;
        }

        private int At(int position) => position < d.Length ? d[position] : -1;

        private void SkipSpace()
        {
            while (_p < d.Length)
            {
                byte c = d[_p];
                if (IsWhite(c)) _p++;
                else if (c == '%')
                {
                    while (_p < d.Length && d[_p] is not (10 or 13)) _p++;
                }
                else return;
            }
        }

        /// <summary>The operand at the position, or null (nothing consumed) at a keyword, a closing delimiter or the end.</summary>
        private PdfObject? ReadValue(int depth)
        {
            SkipSpace();
            if (_p >= d.Length) return null;
            byte c = d[_p];
            switch (c)
            {
                case (byte)'/': return ReadName();
                case (byte)'(': return ReadLiteral();
                case (byte)'<': return At(_p + 1) == '<' ? ReadDictionary(depth) : ReadHex();
                case (byte)'[': return ReadArray(depth);
            }
            if (c is (>= (byte)'0' and <= (byte)'9') or (byte)'+' or (byte)'-' or (byte)'.') return ReadNumber();
            if (IsDelimiter(c)) return null;
            int end = _p;
            while (end < d.Length && IsRegular(d[end])) end++;
            ReadOnlySpan<byte> word = d.AsSpan(_p, end - _p);
            PdfObject? literal = null;
            if (word.SequenceEqual("true"u8)) literal = new PdfBoolean(true);
            else if (word.SequenceEqual("false"u8)) literal = new PdfBoolean(false);
            else if (word.SequenceEqual("null"u8)) literal = PdfNull.Instance;
            if (literal is not null) _p = end;
            return literal;
        }

        // "--5" is -5, "1.2.3" is 1.2 and then .3, "-" and "." are 0.
        private PdfNumber ReadNumber()
        {
            int start = _p;
            bool negative = d[_p] == '-';
            while (_p < d.Length && d[_p] is (byte)'+' or (byte)'-') _p++;
            bool plainSign = _p - start <= 1;
            int digitsStart = _p;
            while (_p < d.Length && d[_p] is >= (byte)'0' and <= (byte)'9') _p++;
            int whole = _p - digitsStart;
            int fraction = 0;
            if (_p < d.Length && d[_p] == '.')
            {
                _p++;
                int from = _p;
                while (_p < d.Length && d[_p] is >= (byte)'0' and <= (byte)'9') _p++;
                fraction = _p - from;
            }
            if (whole == 0 && fraction == 0) return new PdfNumber("0");
            if (plainSign) return new PdfNumber(Encoding.Latin1.GetString(d, start, _p - start));
            return new PdfNumber((negative ? "-" : "") + Encoding.Latin1.GetString(d, digitsStart, _p - digitsStart));
        }

        private string ReadWord()
        {
            int start = _p;
            while (_p < d.Length && IsRegular(d[_p])) _p++;
            int length = Math.Min(_p - start, MaxOperatorLength);
            Span<char> chars = stackalloc char[MaxOperatorLength];
            for (int i = 0; i < length; i++) chars[i] = (char)d[start + i];
            return _known.TryGetValue(chars[..length], out var known) ? known : new string(chars[..length]);
        }

        private PdfName ReadName()
        {
            _p++;
            int start = _p;
            bool escaped = false;
            while (_p < d.Length && IsRegular(d[_p]))
            {
                if (d[_p] == '#') escaped = true;
                _p++;
            }
            if (!escaped) return new PdfName(Encoding.Latin1.GetString(d, start, _p - start));
            var sb = new StringBuilder();
            for (int i = start; i < _p; i++)
            {
                if (d[i] == '#' && i + 2 < _p && Hex(d[i + 1]) >= 0 && Hex(d[i + 2]) >= 0)
                {
                    sb.Append((char)(Hex(d[i + 1]) * 16 + Hex(d[i + 2])));
                    i += 2;
                }
                else sb.Append((char)d[i]);
            }
            return new PdfName(sb.ToString());
        }

        private PdfString ReadLiteral()
        {
            _p++;
            _text.Clear();
            int depth = 1;
            while (_p < d.Length)
            {
                byte c = d[_p++];
                if (c == '\\' && _p < d.Length)
                {
                    byte e = d[_p++];
                    switch (e)
                    {
                        case (byte)'n': _text.Add(10); break;
                        case (byte)'r': _text.Add(13); break;
                        case (byte)'t': _text.Add(9); break;
                        case (byte)'b': _text.Add(8); break;
                        case (byte)'f': _text.Add(12); break;
                        case 13:
                            if (At(_p) == 10) _p++;
                            break;
                        case 10: break;
                        case >= (byte)'0' and <= (byte)'7':
                            int value = e - '0';
                            for (int k = 0; k < 2 && At(_p) is >= '0' and <= '7'; k++) value = value * 8 + (d[_p++] - '0');
                            _text.Add((byte)value);
                            break;
                        default: _text.Add(e); break;
                    }
                    continue;
                }
                if (c == '(') depth++;
                else if (c == ')' && --depth == 0) break;
                if (c == 13)
                {
                    if (At(_p) == 10) _p++;
                    c = 10;
                }
                _text.Add(c);
            }
            return new PdfString([.. _text], isHex: false);
        }

        private PdfString ReadHex()
        {
            _p++;
            _text.Clear();
            int high = -1;
            while (_p < d.Length)
            {
                byte c = d[_p++];
                if (c == '>') break;
                int h = Hex(c);
                if (h < 0) continue;
                if (high < 0) high = h;
                else
                {
                    _text.Add((byte)(high * 16 + h));
                    high = -1;
                }
            }
            if (high >= 0) _text.Add((byte)(high * 16));
            return new PdfString([.. _text], isHex: true);
        }

        private PdfArray ReadArray(int depth)
        {
            _p++;
            var items = new List<PdfObject>();
            if (depth >= MaxDepth) return new PdfArray(items);
            while (true)
            {
                SkipSpace();
                if (_p >= d.Length) break;
                if (d[_p] == ']')
                {
                    _p++;
                    break;
                }
                var value = ReadValue(depth + 1);
                if (value is not null)
                {
                    items.Add(value);
                    continue;
                }
                if (IsDelimiter(d[_p]))
                {
                    _p++;
                    continue;
                }
                // A missing ] ends at the next real operator.
                int at = _p;
                if (Known.ContainsKey(ReadWord()))
                {
                    _p = at;
                    break;
                }
            }
            return new PdfArray(items);
        }

        private PdfDictionary ReadDictionary(int depth)
        {
            _p += 2;
            var dictionary = new PdfDictionary();
            if (depth >= MaxDepth) return dictionary;
            while (true)
            {
                SkipSpace();
                if (_p >= d.Length) break;
                if (d[_p] == '>')
                {
                    _p += At(_p + 1) == '>' ? 2 : 1;
                    break;
                }
                if (d[_p] == '/')
                {
                    string key = ReadName().Value;
                    SkipSpace();
                    if (At(_p) == '>' && At(_p + 1) == '>') dictionary.Add(key, PdfNull.Instance);
                    else if (ReadValue(depth + 1) is { } value) dictionary.Add(key, value);
                    continue;
                }
                if (ReadValue(depth + 1) is not null) continue;
                if (IsDelimiter(d[_p]))
                {
                    _p++;
                    continue;
                }
                int at = _p;
                if (Known.ContainsKey(ReadWord()))
                {
                    _p = at;
                    break;
                }
            }
            return dictionary;
        }

        private InlineImage ReadInlineImage()
        {
            var dictionary = new PdfDictionary();
            while (true)
            {
                SkipSpace();
                if (_p >= d.Length) return new InlineImage(dictionary, []);
                if (d[_p] == '/')
                {
                    string key = ReadName().Value;
                    if (ReadValue(0) is { } value) dictionary.Add(key, value);
                    continue;
                }
                if (ReadValue(0) is not null) continue;
                if (IsDelimiter(d[_p]))
                {
                    _p++;
                    continue;
                }
                string word = ReadWord();
                if (word == "ID") break;
                if (word == "EI") return new InlineImage(dictionary, []);
            }
            // One white space byte follows ID; CR LF counts as one.
            if (At(_p) == 13 && At(_p + 1) == 10) _p += 2;
            else if (IsWhite(At(_p))) _p++;
            int start = _p;
            int end = FindImageEnd(dictionary, start, out int next);
            _p = next;
            return new InlineImage(dictionary, d[start..end]);
        }

        private int FindImageEnd(PdfDictionary dictionary, int start, out int next)
        {
            long length = KnownLength(dictionary);
            if (length >= 0 && length <= d.Length - start)
            {
                int at = (int)(start + length);
                int q = at;
                while (q < d.Length && IsWhite(d[q])) q++;
                if (At(q) == 'E' && At(q + 1) == 'I' && (q + 2 >= d.Length || !IsRegular(d[q + 2])))
                {
                    next = q + 2;
                    return at;
                }
            }
            for (int i = start; i + 1 < d.Length; i++)
            {
                if (d[i] != 'E' || d[i + 1] != 'I') continue;
                if (i > start && !IsWhite(d[i - 1])) continue;
                if (i + 2 < d.Length && IsRegular(d[i + 2])) continue;
                if (!LooksLikeContent(i + 2)) continue;
                next = i + 2;
                return i > start ? i - 1 : i;
            }
            next = d.Length;
            return d.Length;
        }

        // Binary data holds "EI" by chance now and then; what follows a real one reads as a content stream.
        private bool LooksLikeContent(int from)
        {
            int p = from;
            while (p < d.Length && IsWhite(d[p])) p++;
            int end = Math.Min(d.Length, p + 20);
            for (int i = p; i < end; i++)
            {
                byte c = d[i];
                if (c > 126 || (c < 32 && !IsWhite(c))) return false;
            }
            if (p >= d.Length || !char.IsAsciiLetter((char)d[p])) return true;
            int save = _p;
            _p = p;
            string word = ReadWord();
            _p = save;
            return Known.ContainsKey(word);
        }

        // The size of unfiltered data, when width, height and colour space say it.
        private static long KnownLength(PdfDictionary dictionary)
        {
            if (dictionary["F"] is not null || dictionary["Filter"] is not null) return -1;
            if ((dictionary["W"] ?? dictionary["Width"]) is not PdfNumber { Value: > 0 } w
                || (dictionary["H"] ?? dictionary["Height"]) is not PdfNumber { Value: > 0 } h) return -1;
            int bits = (dictionary["BPC"] ?? dictionary["BitsPerComponent"]) is PdfNumber b ? (int)b.Value : 8;
            int components;
            if ((dictionary["IM"] ?? dictionary["ImageMask"]) is PdfBoolean { Value: true })
            {
                bits = 1;
                components = 1;
            }
            else
            {
                var space = dictionary["CS"] ?? dictionary["ColorSpace"];
                if (space is PdfArray { Items.Count: > 0 } array) space = array.Items[0];
                components = (space as PdfName)?.Value switch
                {
                    "G" or "DeviceGray" or "I" or "Indexed" => 1,
                    "RGB" or "DeviceRGB" => 3,
                    "CMYK" or "DeviceCMYK" => 4,
                    _ => 0,
                };
            }
            if (components == 0 || bits is not (1 or 2 or 4 or 8 or 16)) return -1;
            return ((long)w.Value * components * bits + 7) / 8 * (long)h.Value;
        }
    }
}
