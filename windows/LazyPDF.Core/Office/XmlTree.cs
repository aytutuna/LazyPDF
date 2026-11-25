using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>What an XML part may hold. Counts include namespace declarations; a document over a limit is refused, not cut.</summary>
internal sealed record XmlLimits(int MaxDepth = 128, int MaxElements = 1_000_000, int MaxAttributes = 128)
{
    public static readonly XmlLimits Default = new();
}

internal abstract class XmlNode;

internal sealed class XmlText(string value) : XmlNode
{
    public string Value { get; } = value;
}

internal sealed record XmlAttribute(string Uri, string Name, string Value);

/// <summary>An element with its namespace resolved: <see cref="Uri"/> and the local <see cref="Name"/>. Namespace declarations are not attributes.</summary>
internal sealed class XmlElement(string uri, string name, IReadOnlyList<XmlAttribute> attributes) : XmlNode
{
    public string Uri { get; } = uri;
    public string Name { get; } = name;
    public IReadOnlyList<XmlAttribute> Attributes { get; } = attributes;
    public List<XmlNode> Children { get; } = [];

    public IEnumerable<XmlElement> Elements() => Children.OfType<XmlElement>();

    public IEnumerable<XmlElement> Elements(string uri, string name) => Elements().Where(e => e.Uri == uri && e.Name == name);

    public XmlElement? Child(string uri, string name) => Elements(uri, name).FirstOrDefault();

    public string? Attribute(string uri, string name) => Attributes.FirstOrDefault(a => a.Uri == uri && a.Name == name)?.Value;

    /// <summary>An attribute with no namespace, which is how most of them are written.</summary>
    public string? Attribute(string name) => Attribute("", name);

    /// <summary>The text directly inside the element, CDATA included, without that of its children.</summary>
    public string Text => string.Concat(Children.OfType<XmlText>().Select(t => t.Value));
}

/// <summary>
/// A small non-validating XML reader for OOXML parts, written so that the C# and Swift engines read a part alike (the platform
/// parsers differ on the odd cases). It reads UTF-8 and UTF-16 (BOM or not, strictly: bad bytes fail), elements, attributes,
/// namespaces with prefixes resolved, text, CDATA and the five predefined entities and numeric references. Line ends are
/// normalized as the XML rules say. There is no DTD: a DOCTYPE is refused, so no entity can be defined, let alone fetched.
/// Comments and processing instructions are dropped. Raw characters are not checked against the XML character ranges. Text on
/// both sides of a comment is one text node. The parse is iterative, so depth costs nothing on the stack.
/// </summary>
internal static class XmlTree
{
    private const string XmlUri = "http://www.w3.org/XML/1998/namespace";

    private sealed record Frame(XmlElement Element, string QName, List<string> Declared);

    public static XmlElement Parse(byte[] data, XmlLimits? limits = null) => new Parser(Decode(data), limits ?? XmlLimits.Default).Run();

    private static string Decode(byte[] d)
    {
        Encoding encoding = new UTF8Encoding(false, true);
        int skip = 0;
        if (d.Length >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF)
        {
            skip = 3;
        }
        else if (d.Length >= 2 && (d[0] == 0xFE && d[1] == 0xFF || d[0] == 0 && d[1] == 0x3C))
        {
            encoding = new UnicodeEncoding(true, false, true);
            skip = d[0] == 0xFE ? 2 : 0;
        }
        else if (d.Length >= 2 && (d[0] == 0xFF && d[1] == 0xFE || d[0] == 0x3C && d[1] == 0))
        {
            encoding = new UnicodeEncoding(false, false, true);
            skip = d[0] == 0xFF ? 2 : 0;
        }
        try
        {
            return encoding.GetString(d, skip, d.Length - skip);
        }
        catch (ArgumentException)
        {
            throw Bad("the text is not valid UTF-8 or UTF-16.");
        }
    }

    private static PdfReadException Bad(string what) => PdfReadException.Damaged($"The XML is damaged: {what}");

    private static PdfReadException Refused(string what) => new(PdfReadProblem.Unsupported, $"The XML is refused: {what}.");

    private sealed class Parser(string s, XmlLimits limits)
    {
        private int _i;
        private int _elements;
        private readonly List<Frame> _stack = [];
        private readonly Dictionary<string, List<string>> _bound = new() { ["xml"] = [XmlUri] };
        private readonly StringBuilder _text = new();
        private XmlElement? _root;

        public XmlElement Run()
        {
            while (_i < s.Length)
            {
                if (s[_i] != '<') CharData();
                else if (Starts("<?")) Instruction();
                else if (Starts("<!--")) Comment();
                else if (Starts("<![CDATA[")) Cdata();
                else if (Starts("<!DOCTYPE")) throw Refused("a document type is not allowed");
                else if (Starts("<!")) throw Bad("unknown markup declaration.");
                else if (Starts("</")) EndTag();
                else StartTag();
            }
            if (_stack.Count > 0) throw Bad("an element is not closed.");
            return _root ?? throw Bad("there is no root element.");
        }

        private bool Starts(string t) => string.CompareOrdinal(s, _i, t, 0, t.Length) == 0;

        private static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\r';

        private static bool IsNameStart(char c) => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or '_' or ':' or >= '\u0080';

        private static bool IsNameChar(char c) => IsNameStart(c) || c is >= '0' and <= '9' or '-' or '.';

        private void SkipSpace()
        {
            while (_i < s.Length && IsSpace(s[_i])) _i++;
        }

        private string Name()
        {
            int start = _i;
            if (_i >= s.Length || !IsNameStart(s[_i])) throw Bad("a name was expected.");
            while (_i < s.Length && IsNameChar(s[_i])) _i++;
            return s[start.._i];
        }

        private void CharData()
        {
            bool inside = _stack.Count > 0;
            while (_i < s.Length && s[_i] != '<')
            {
                char c = s[_i];
                if (!inside)
                {
                    if (!IsSpace(c)) throw Bad("text outside the root element.");
                    _i++;
                }
                else if (c == '&')
                {
                    _i++;
                    Reference(_text);
                }
                else if (c == '\r')
                {
                    _i++;
                    if (_i < s.Length && s[_i] == '\n') _i++;
                    _text.Append('\n');
                }
                else
                {
                    _text.Append(c);
                    _i++;
                }
            }
        }

        private void Reference(StringBuilder into)
        {
            if (_i < s.Length && s[_i] == '#')
            {
                _i++;
                bool hex = _i < s.Length && s[_i] == 'x';
                if (hex) _i++;
                int start = _i;
                long value = 0;
                while (_i < s.Length && s[_i] != ';')
                {
                    int digit = Digit(s[_i], hex);
                    if (digit < 0 || _i - start >= 8) throw Bad("a character reference is not a number.");
                    value = value * (hex ? 16 : 10) + digit;
                    _i++;
                }
                if (_i >= s.Length || _i == start) throw Bad("a character reference is not closed.");
                _i++;
                bool ok = value is 9 or 10 or 13 or >= 0x20 and <= 0xD7FF or >= 0xE000 and <= 0xFFFD or >= 0x10000 and <= 0x10FFFF;
                if (!ok) throw Bad("a character reference is not a legal character.");
                into.Append(char.ConvertFromUtf32((int)value));
                return;
            }
            int end = s.IndexOf(';', _i, Math.Min(5, s.Length - _i));
            if (end < 0) throw Bad("an entity is not closed or not known.");
            string name = s[_i..end];
            char? c = name switch { "lt" => '<', "gt" => '>', "amp" => '&', "quot" => '"', "apos" => '\'', _ => null };
            if (c is null) throw Bad($"the entity &{name}; is not defined.");
            into.Append(c.Value);
            _i = end + 1;
        }

        private static int Digit(char c, bool hex) => c switch
        {
            >= '0' and <= '9' => c - '0',
            >= 'a' and <= 'f' when hex => c - 'a' + 10,
            >= 'A' and <= 'F' when hex => c - 'A' + 10,
            _ => -1,
        };

        private void Comment()
        {
            int end = s.IndexOf("-->", _i + 4, StringComparison.Ordinal);
            if (end < 0) throw Bad("a comment is not closed.");
            _i = end + 3;
        }

        private void Cdata()
        {
            if (_stack.Count == 0) throw Bad("CDATA outside the root element.");
            int end = s.IndexOf("]]>", _i + 9, StringComparison.Ordinal);
            if (end < 0) throw Bad("a CDATA section is not closed.");
            for (int k = _i + 9; k < end; k++)
            {
                if (s[k] == '\r' && k + 1 < end && s[k + 1] == '\n') continue;
                _text.Append(s[k] == '\r' ? '\n' : s[k]);
            }
            _i = end + 3;
        }

        private void Instruction()
        {
            bool first = _i == 0;
            _i += 2;
            string target = Name();
            int end = s.IndexOf("?>", _i, StringComparison.Ordinal);
            if (end < 0) throw Bad("a processing instruction is not closed.");
            if (string.Equals(target, "xml", StringComparison.OrdinalIgnoreCase))
            {
                if (!first || target != "xml") throw Bad("the XML declaration is not at the start.");
                CheckEncoding(s[_i..end]);
            }
            _i = end + 2;
        }

        private static void CheckEncoding(string declaration)
        {
            int at = declaration.IndexOf("encoding", StringComparison.Ordinal);
            if (at < 0) return;
            int q = declaration.IndexOfAny(['"', '\''], at);
            int close = q < 0 ? -1 : declaration.IndexOf(declaration[q], q + 1);
            if (close < 0) throw Bad("the encoding in the declaration is not quoted.");
            string name = declaration[(q + 1)..close].ToLowerInvariant();
            if (name is not ("utf-8" or "utf-16" or "us-ascii")) throw Refused($"the encoding {name} is not supported");
        }

        private void Flush()
        {
            if (_text.Length == 0) return;
            _stack[^1].Element.Children.Add(new XmlText(_text.ToString()));
            _text.Clear();
        }

        private void StartTag()
        {
            _i++;
            string qname = Name();
            var raw = new List<(string Name, string Value)>();
            bool empty = false;
            while (true)
            {
                int before = _i;
                SkipSpace();
                if (_i >= s.Length) throw Bad("a tag is not closed.");
                if (s[_i] == '>')
                {
                    _i++;
                    break;
                }
                if (s[_i] == '/')
                {
                    if (_i + 1 >= s.Length || s[_i + 1] != '>') throw Bad("a tag is not closed.");
                    _i += 2;
                    empty = true;
                    break;
                }
                if (_i == before) throw Bad("attributes need a space before them.");
                string name = Name();
                SkipSpace();
                if (_i >= s.Length || s[_i] != '=') throw Bad("an attribute has no value.");
                _i++;
                SkipSpace();
                if (_i >= s.Length || s[_i] is not ('"' or '\'')) throw Bad("an attribute value is not quoted.");
                if (raw.Any(r => r.Name == name)) throw Bad($"the attribute {name} is given twice.");
                raw.Add((name, AttributeValue()));
                if (raw.Count > limits.MaxAttributes) throw Refused("an element has too many attributes");
            }
            if (_root is not null && _stack.Count == 0) throw Bad("there is more than one root element.");
            if (++_elements > limits.MaxElements) throw Refused("the part has too many elements");
            if (_stack.Count >= limits.MaxDepth) throw Refused("the elements are nested too deep");
            if (_stack.Count > 0) Flush();

            var declared = new List<string>();
            foreach (var (name, value) in raw)
            {
                string? prefix = name == "xmlns" ? "" : name.StartsWith("xmlns:", StringComparison.Ordinal) ? name[6..] : null;
                if (prefix is null) continue;
                if (prefix == "xmlns" || prefix == "xml" && value != XmlUri || prefix != "" && value.Length == 0) throw Bad("a namespace declaration is not allowed.");
                if (prefix != "xml") Bind(prefix, value, declared);
            }
            var (uri, local) = Resolve(qname, true);
            var attributes = new List<XmlAttribute>();
            foreach (var (name, value) in raw)
            {
                if (name == "xmlns" || name.StartsWith("xmlns:", StringComparison.Ordinal)) continue;
                var (auri, alocal) = Resolve(name, false);
                if (attributes.Any(a => a.Uri == auri && a.Name == alocal)) throw Bad($"the attribute {name} is given twice.");
                attributes.Add(new XmlAttribute(auri, alocal, value));
            }
            var el = new XmlElement(uri, local, attributes);
            if (_stack.Count > 0) _stack[^1].Element.Children.Add(el);
            else _root = el;
            if (empty) Unbind(declared);
            else _stack.Add(new Frame(el, qname, declared));
        }

        private static bool IsLocalName(string n) => n.Length > 0 && IsNameStart(n[0]) && n[0] != ':' && !n.Contains(':');

        private void Bind(string prefix, string uri, List<string> declared)
        {
            if (prefix.Length > 0 && !IsLocalName(prefix)) throw Bad("a namespace prefix is not a name.");
            if (!_bound.TryGetValue(prefix, out var uris)) _bound[prefix] = uris = [];
            uris.Add(uri);
            declared.Add(prefix);
        }

        private void Unbind(List<string> declared)
        {
            foreach (string prefix in declared) _bound[prefix].RemoveAt(_bound[prefix].Count - 1);
        }

        private (string Uri, string Local) Resolve(string qname, bool isElement)
        {
            int colon = qname.IndexOf(':');
            if (colon < 0)
            {
                string uri = isElement && _bound.TryGetValue("", out var d) && d.Count > 0 ? d[^1] : "";
                return (uri, qname);
            }
            string prefix = qname[..colon], local = qname[(colon + 1)..];
            if (!IsLocalName(local) || !IsLocalName(prefix)) throw Bad($"the name {qname} is not a qualified name.");
            if (!_bound.TryGetValue(prefix, out var uris) || uris.Count == 0) throw Bad($"the prefix {prefix} is not declared.");
            return (uris[^1], local);
        }

        private string AttributeValue()
        {
            char quote = s[_i++];
            var sb = new StringBuilder();
            while (true)
            {
                if (_i >= s.Length) throw Bad("an attribute value is not closed.");
                char c = s[_i];
                if (c == quote)
                {
                    _i++;
                    return sb.ToString();
                }
                if (c == '<') throw Bad("an attribute value has a <.");
                _i++;
                if (c == '&') Reference(sb);
                else if (c == '\r')
                {
                    if (_i < s.Length && s[_i] == '\n') _i++;
                    sb.Append(' ');
                }
                else sb.Append(c is '\n' or '\t' ? ' ' : c);
            }
        }

        private void EndTag()
        {
            _i += 2;
            string qname = Name();
            SkipSpace();
            if (_i >= s.Length || s[_i] != '>') throw Bad("an end tag is not closed.");
            _i++;
            if (_stack.Count == 0 || _stack[^1].QName != qname) throw Bad($"the end tag {qname} does not match.");
            Flush();
            Unbind(_stack[^1].Declared);
            _stack.RemoveAt(_stack.Count - 1);
        }
    }
}
