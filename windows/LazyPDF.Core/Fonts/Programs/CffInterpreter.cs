using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

/// <summary>Type 2 charstring interpreter (Adobe TN 5177): outline and advance width of one glyph.</summary>
internal sealed class CffInterpreter(CffFont font, CffPrivate priv, bool widthOnly, bool allowSeac)
{
    private const int MaxDepth = 10;
    private const int MaxOperators = 200_000;

    private readonly double[] _s = new double[96];
    private readonly GlyphOutline _out = new();
    private double[]? _transient;
    private int _n;
    private double _x, _y;
    private bool _open;
    private bool _haveWidth;
    private bool _done;
    private int _stems;
    private int _ops;
    private double _width = priv.DefaultWidth;

    public CffGlyph Run(int glyphId)
    {
        Exec(font.CharString(glyphId), 0);
        EndPath();
        return new CffGlyph(_out, _width);
    }

    private static int Bias(int count) => count < 1240 ? 107 : count < 33900 ? 1131 : 32768;

    private void Exec(ReadOnlySpan<byte> code, int depth)
    {
        for (var p = 0; p < code.Length && !_done;)
        {
            if (++_ops > MaxOperators)
            {
                _done = true;
                return;
            }
            int b = code[p++];
            if (b >= 32 || b == 28)
            {
                double v;
                if (b == 28)
                {
                    v = I16(code, p);
                    p += 2;
                }
                else if (b <= 246) v = b - 139;
                else if (b <= 250) v = (b - 247) * 256 + U8(code, p++) + 108;
                else if (b <= 254) v = -(b - 251) * 256 - U8(code, p++) - 108;
                else
                {
                    v = (int)U32(code, p) / 65536.0;
                    p += 4;
                }
                if (_n < _s.Length) _s[_n++] = v;
                else _done = true;
                continue;
            }

            switch (b)
            {
                case 1 or 3 or 18 or 23:
                    TakeWidth((_n & 1) == 1);
                    _stems += _n / 2;
                    _n = 0;
                    break;
                case 19 or 20:
                    TakeWidth((_n & 1) == 1);
                    _stems += _n / 2;
                    _n = 0;
                    p += (_stems + 7) / 8;
                    break;
                case 21:
                    TakeWidth(_n > 2);
                    if (_n >= 2) MoveTo(_s[_n - 2], _s[_n - 1]);
                    _n = 0;
                    break;
                case 22:
                    TakeWidth(_n > 1);
                    if (_n >= 1) MoveTo(_s[_n - 1], 0);
                    _n = 0;
                    break;
                case 4:
                    TakeWidth(_n > 1);
                    if (_n >= 1) MoveTo(0, _s[_n - 1]);
                    _n = 0;
                    break;
                case 5:
                    for (var i = 0; i + 1 < _n; i += 2) LineTo(_s[i], _s[i + 1]);
                    _n = 0;
                    break;
                case 6 or 7:
                    for (var i = 0; i < _n; i++)
                    {
                        var horizontal = (i % 2 == 0) == (b == 6);
                        LineTo(horizontal ? _s[i] : 0, horizontal ? 0 : _s[i]);
                    }
                    _n = 0;
                    break;
                case 8:
                    for (var i = 0; i + 5 < _n; i += 6) Curve(_s[i], _s[i + 1], _s[i + 2], _s[i + 3], _s[i + 4], _s[i + 5]);
                    _n = 0;
                    break;
                case 24:
                {
                    var i = 0;
                    for (; i + 7 < _n; i += 6) Curve(_s[i], _s[i + 1], _s[i + 2], _s[i + 3], _s[i + 4], _s[i + 5]);
                    if (i + 1 < _n) LineTo(_s[i], _s[i + 1]);
                    _n = 0;
                    break;
                }
                case 25:
                {
                    var i = 0;
                    for (; i + 7 < _n; i += 2) LineTo(_s[i], _s[i + 1]);
                    if (i + 5 < _n) Curve(_s[i], _s[i + 1], _s[i + 2], _s[i + 3], _s[i + 4], _s[i + 5]);
                    _n = 0;
                    break;
                }
                case 26:
                {
                    var i = 0;
                    var dx1 = 0.0;
                    if ((_n & 1) == 1) dx1 = _s[i++];
                    for (; i + 3 < _n; i += 4, dx1 = 0) Curve(dx1, _s[i], _s[i + 1], _s[i + 2], 0, _s[i + 3]);
                    _n = 0;
                    break;
                }
                case 27:
                {
                    var i = 0;
                    var dy1 = 0.0;
                    if ((_n & 1) == 1) dy1 = _s[i++];
                    for (; i + 3 < _n; i += 4, dy1 = 0) Curve(_s[i], dy1, _s[i + 1], _s[i + 2], _s[i + 3], 0);
                    _n = 0;
                    break;
                }
                case 30 or 31:
                    AlternatingCurves(b == 31);
                    _n = 0;
                    break;
                case 10 or 29:
                    if (_n == 0) break;
                    var subrs = b == 10 ? priv.Subrs : font.GlobalSubrs;
                    var index = (int)_s[--_n] + Bias(subrs.Count);
                    if (depth < MaxDepth) Exec(subrs.Item(font.Bytes, index), depth + 1);
                    break;
                case 11:
                    return;
                case 14:
                    TakeWidth(_n is 1 or 5);
                    if (allowSeac && _n >= 4) Seac(_s[_n - 4], _s[_n - 3], (int)_s[_n - 2], (int)_s[_n - 1]);
                    _n = 0;
                    _done = true;
                    break;
                case 12:
                    Escape(U8(code, p++));
                    break;
                default:
                    _n = 0;
                    break;
            }
        }
    }

    private void TakeWidth(bool present)
    {
        if (_haveWidth) return;
        _haveWidth = true;
        if (present && _n > 0)
        {
            _width = priv.NominalWidth + _s[0];
            Array.Copy(_s, 1, _s, 0, _n - 1);
            _n--;
        }
        if (widthOnly) _done = true;
    }

    private void EndPath()
    {
        if (!_open) return;
        _out.Close();
        _open = false;
    }

    private void MoveTo(double dx, double dy)
    {
        EndPath();
        _x += dx;
        _y += dy;
        _out.MoveTo(_x, _y);
        _open = true;
    }

    private void Begin()
    {
        if (_open) return;
        _out.MoveTo(_x, _y);
        _open = true;
    }

    private void LineTo(double dx, double dy)
    {
        Begin();
        _x += dx;
        _y += dy;
        _out.LineTo(_x, _y);
    }

    private void Curve(double dx1, double dy1, double dx2, double dy2, double dx3, double dy3)
    {
        Begin();
        var x1 = _x + dx1;
        var y1 = _y + dy1;
        var x2 = x1 + dx2;
        var y2 = y1 + dy2;
        _x = x2 + dx3;
        _y = y2 + dy3;
        _out.CubicTo(x1, y1, x2, y2, _x, _y);
    }

    private void AlternatingCurves(bool horizontalFirst)
    {
        var horizontal = horizontalFirst;
        for (var i = 0; i + 3 < _n; i += 4, horizontal = !horizontal)
        {
            var extra = _n - i == 5 ? _s[i + 4] : 0;
            if (horizontal) Curve(_s[i], 0, _s[i + 1], _s[i + 2], extra, _s[i + 3]);
            else Curve(0, _s[i], _s[i + 1], _s[i + 2], _s[i + 3], extra);
        }
    }

    private void Seac(double adx, double ady, int baseCode, int accentCode)
    {
        EndPath();
        Append(baseCode, 0, 0);
        Append(accentCode, adx, ady);
    }

    private void Append(int standardCode, double dx, double dy)
    {
        if (standardCode is < 0 or > 255 || StandardNames.StandardEncoding[standardCode] is not { } name) return;
        var gid = font.GlyphForName(name);
        if (gid == 0) return;
        foreach (var s in font.Interpret(gid, false, false).Outline.Segments)
            _out.Add(s.Op == OutlineOp.Close ? s : s with { X = s.X + dx, Y = s.Y + dy, X1 = s.X1 + dx, Y1 = s.Y1 + dy, X2 = s.X2 + dx, Y2 = s.Y2 + dy });
    }

    private void Escape(int op)
    {
        switch (op)
        {
            case 35 when _n >= 12:
                Curve(_s[0], _s[1], _s[2], _s[3], _s[4], _s[5]);
                Curve(_s[6], _s[7], _s[8], _s[9], _s[10], _s[11]);
                _n = 0;
                break;
            case 34 when _n >= 7:
                Curve(_s[0], 0, _s[1], _s[2], _s[3], 0);
                Curve(_s[4], 0, _s[5], -_s[2], _s[6], 0);
                _n = 0;
                break;
            case 36 when _n >= 9:
                Curve(_s[0], _s[1], _s[2], _s[3], _s[4], 0);
                Curve(_s[5], 0, _s[6], _s[7], _s[8], -(_s[1] + _s[3] + _s[7]));
                _n = 0;
                break;
            case 37 when _n >= 11:
            {
                var dx = _s[0] + _s[2] + _s[4] + _s[6] + _s[8];
                var dy = _s[1] + _s[3] + _s[5] + _s[7] + _s[9];
                Curve(_s[0], _s[1], _s[2], _s[3], _s[4], _s[5]);
                if (Math.Abs(dx) > Math.Abs(dy)) Curve(_s[6], _s[7], _s[8], _s[9], _s[10], -dy);
                else Curve(_s[6], _s[7], _s[8], _s[9], -dx, _s[10]);
                _n = 0;
                break;
            }
            case 35 or 34 or 36 or 37:
                _n = 0;
                break;
            default:
                Arithmetic(op);
                break;
        }
    }

    private void Arithmetic(int op)
    {
        switch (op)
        {
            case 3 or 4 or 10 or 11 or 12 or 15 or 24 or 28 when _n >= 2:
            {
                var b = _s[--_n];
                var a = _s[--_n];
                switch (op)
                {
                    case 3: Push(a != 0 && b != 0 ? 1 : 0); break;
                    case 4: Push(a != 0 || b != 0 ? 1 : 0); break;
                    case 10: Push(a + b); break;
                    case 11: Push(a - b); break;
                    case 12: Push(b == 0 ? 0 : a / b); break;
                    case 15: Push(a == b ? 1 : 0); break;
                    case 24: Push(a * b); break;
                    default:
                        Push(b);
                        Push(a);
                        break;
                }
                break;
            }
            case 5 or 9 or 14 or 26 or 18 or 27 or 21 or 29 when _n >= 1:
            {
                var a = _s[--_n];
                switch (op)
                {
                    case 5: Push(a == 0 ? 1 : 0); break;
                    case 9: Push(Math.Abs(a)); break;
                    case 14: Push(-a); break;
                    case 26: Push(Math.Sqrt(Math.Abs(a))); break;
                    case 27:
                        Push(a);
                        Push(a);
                        break;
                    case 21: Push(_transient is { } t && a >= 0 && a < t.Length ? t[(int)a] : 0); break;
                    case 29:
                        var from = _n - 1 - (a < 0 ? 0 : (int)Math.Min(a, _n - 1));
                        Push(from >= 0 ? _s[from] : 0);
                        break;
                }
                break;
            }
            case 20 when _n >= 2:
            {
                var index = _s[--_n];
                var value = _s[--_n];
                _transient ??= new double[32];
                if (index >= 0 && index < _transient.Length) _transient[(int)index] = value;
                break;
            }
            case 22 when _n >= 4:
            {
                var v2 = _s[--_n];
                var v1 = _s[--_n];
                var s2 = _s[--_n];
                var s1 = _s[--_n];
                Push(v1 <= v2 ? s1 : s2);
                break;
            }
            case 23:
                Push(0.5);
                break;
            case 30 when _n >= 2:
            {
                var j = (int)_s[--_n];
                var count = (int)_s[--_n];
                if (count <= 0 || count > _n) break;
                var top = _n - count;
                var copy = _s.AsSpan(top, count).ToArray();
                for (var i = 0; i < count; i++) _s[top + ((i + j) % count + count) % count] = copy[i];
                break;
            }
            default:
                _n = 0;
                break;
        }
    }

    private void Push(double v)
    {
        if (_n < _s.Length) _s[_n++] = v;
    }
}
