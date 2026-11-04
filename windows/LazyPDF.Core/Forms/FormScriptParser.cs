using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

/// <summary>A call of one of the built-in form functions, its arguments as numbers, strings, booleans, null or lists of those.</summary>
internal sealed record FormCall(string Name, IReadOnlyList<object?> Args)
{
    public double Number(int index, double fallback = 0) => index < Args.Count && Args[index] is double d ? d : fallback;

    public string Text(int index, string fallback = "") => index < Args.Count && Args[index] is string s ? s : fallback;

    public bool Flag(int index, bool fallback = false) => index < Args.Count && Args[index] is bool b ? b : fallback;
}

/// <summary>
/// Reads the text of an action's JavaScript when it is nothing but calls of the AF functions Acrobat
/// writes for the standard formats, calculations and ranges. Anything else is not understood and not run.
/// </summary>
internal sealed class FormScriptParser
{
    private const int MaxLength = 4096;
    private const int MaxCalls = 64;
    private const int MaxArgs = 256;
    private const int MaxDepth = 8;

    private static readonly HashSet<string> Known = new(StringComparer.Ordinal)
    {
        "AFNumber_Format", "AFNumber_Keystroke", "AFPercent_Format", "AFPercent_Keystroke",
        "AFDate_Format", "AFDate_FormatEx", "AFDate_Keystroke", "AFDate_KeystrokeEx",
        "AFTime_Format", "AFTime_FormatEx", "AFTime_Keystroke", "AFTime_KeystrokeEx",
        "AFSpecial_Format", "AFSpecial_Keystroke", "AFSpecial_KeystrokeEx",
        "AFSimple_Calculate", "AFRange_Validate",
    };

    private readonly string _text;
    private int _at;

    private FormScriptParser(string text) => _text = text;

    /// <summary>The calls in the text, or null when it holds anything else.</summary>
    public static IReadOnlyList<FormCall>? Parse(string source)
    {
        if (source.Length > MaxLength) return null;
        var parser = new FormScriptParser(source);
        var calls = new List<FormCall>();
        while (true)
        {
            parser.Skip();
            if (parser._at >= source.Length) return calls.Count > 0 ? calls : null;
            if (calls.Count >= MaxCalls || parser.Call() is not { } call) return null;
            calls.Add(call);
            parser.Skip();
            if (parser.Peek() == ';') parser._at++;
        }
    }

    private FormCall? Call()
    {
        string name = Identifier();
        Skip();
        if (!Known.Contains(name) || Peek() != '(') return null;
        _at++;
        return Arguments(')', 0) is { } args ? new FormCall(name, args) : null;
    }

    private List<object?>? Arguments(char close, int depth)
    {
        var args = new List<object?>();
        Skip();
        if (Peek() == close)
        {
            _at++;
            return args;
        }
        while (args.Count < MaxArgs)
        {
            if (depth > MaxDepth || !Value(depth, out var value)) return null;
            args.Add(value);
            Skip();
            char c = Peek();
            _at++;
            if (c == close) return args;
            if (c != ',') return null;
        }
        return null;
    }

    private bool Value(int depth, out object? value)
    {
        value = null;
        Skip();
        char c = Peek();
        if (c is '"' or '\'') return Quoted(c, out value);
        if (c == '[')
        {
            _at++;
            value = Arguments(']', depth + 1);
            return value is not null;
        }
        if (c is '-' or '+' or '.' || char.IsAsciiDigit(c))
        {
            int start = _at++;
            while (_at < _text.Length && (char.IsAsciiDigit(_text[_at]) || _text[_at] is '.' or 'e' or 'E')) _at++;
            if (!double.TryParse(_text.AsSpan(start, _at - start), NumberStyles.Float, CultureInfo.InvariantCulture, out double number)) return false;
            value = number;
            return true;
        }
        string word = Identifier();
        switch (word)
        {
            case "true": value = true; return true;
            case "false": value = false; return true;
            case "null": return true;
            case "new" or "Array":
                if (word == "new")
                {
                    Skip();
                    if (Identifier() != "Array") return false;
                }
                Skip();
                if (Peek() != '(') return false;
                _at++;
                value = Arguments(')', depth + 1);
                return value is not null;
            default:
                return false;
        }
    }

    private bool Quoted(char quote, out object? value)
    {
        value = null;
        var sb = new StringBuilder();
        _at++;
        while (_at < _text.Length)
        {
            char c = _text[_at++];
            if (c == quote)
            {
                value = sb.ToString();
                return true;
            }
            if (c != '\\')
            {
                sb.Append(c);
                continue;
            }
            if (_at >= _text.Length) return false;
            char e = _text[_at++];
            if (e == 'u' && _at + 4 <= _text.Length && int.TryParse(_text.AsSpan(_at, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int code))
            {
                sb.Append((char)code);
                _at += 4;
            }
            else sb.Append(e switch { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => e });
        }
        return false;
    }

    private string Identifier()
    {
        int start = _at;
        while (_at < _text.Length && (char.IsAsciiLetterOrDigit(_text[_at]) || _text[_at] is '_' or '$')) _at++;
        return _text[start.._at];
    }

    private char Peek() => _at < _text.Length ? _text[_at] : '\0';

    private void Skip()
    {
        while (_at < _text.Length)
        {
            if (char.IsWhiteSpace(_text[_at])) _at++;
            else if (_text.AsSpan(_at).StartsWith("//")) _at = _text.IndexOf('\n', _at) is var nl and >= 0 ? nl : _text.Length;
            else if (_text.AsSpan(_at).StartsWith("/*")) _at = _text.IndexOf("*/", _at + 2, StringComparison.Ordinal) is var end and >= 0 ? end + 2 : _text.Length;
            else break;
        }
    }
}
