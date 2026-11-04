using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

/// <summary>Type 1 charstring interpreter: outline and advance width of one glyph, flex and seac included.</summary>
internal sealed class Type1Interpreter(Type1Font font, bool allowSeac)
{
    private const int MaxDepth = 10;
    private const int MaxOperators = 200_000;

    private readonly double[] _s = new double[64];
    private readonly List<double> _ps = [];
    private readonly List<(double X, double Y)> _flex = [];
    private readonly GlyphOutline _out = new();
    private int _n;
    private double _x, _y;
    private double _sbx;
    private double _width;
    private bool _open;
    private bool _flexing;
    private bool _done;
    private int _ops;

    public Type1Glyph Run(string name)
    {
        if (font.CharString(name) is { } code) Exec(code, 0);
        Close();
        return new Type1Glyph(_out, _width);
    }

    private void Exec(byte[] code, int depth)
    {
        for (var p = 0; p < code.Length && !_done;)
        {
            if (++_ops > MaxOperators)
            {
                _done = true;
                return;
            }
            int b = code[p++];
            if (b >= 32)
            {
                double v;
                if (b <= 246) v = b - 139;
                else if (b <= 250) v = (b - 247) * 256 + U8(code, p++) + 108;
                else if (b <= 254) v = -(b - 251) * 256 - U8(code, p++) - 108;
                else
                {
                    v = (int)U32(code, p);
                    p += 4;
                }
                Push(v);
                continue;
            }

            switch (b)
            {
                case 13 when _n >= 2:
                    _sbx = _s[0];
                    _width = _s[1];
                    _x = _sbx;
                    _y = 0;
                    _n = 0;
                    break;
                case 4 when _n >= 1:
                    MoveTo(0, _s[_n - 1]);
                    _n = 0;
                    break;
                case 21 when _n >= 2:
                    MoveTo(_s[_n - 2], _s[_n - 1]);
                    _n = 0;
                    break;
                case 22 when _n >= 1:
                    MoveTo(_s[_n - 1], 0);
                    _n = 0;
                    break;
                case 5 when _n >= 2:
                    LineTo(_s[0], _s[1]);
                    _n = 0;
                    break;
                case 6 when _n >= 1:
                    LineTo(_s[0], 0);
                    _n = 0;
                    break;
                case 7 when _n >= 1:
                    LineTo(0, _s[0]);
                    _n = 0;
                    break;
                case 8 when _n >= 6:
                    Curve(_s[0], _s[1], _s[2], _s[3], _s[4], _s[5]);
                    _n = 0;
                    break;
                case 30 when _n >= 4:
                    Curve(0, _s[0], _s[1], _s[2], _s[3], 0);
                    _n = 0;
                    break;
                case 31 when _n >= 4:
                    Curve(_s[0], 0, _s[1], _s[2], 0, _s[3]);
                    _n = 0;
                    break;
                case 9:
                    Close();
                    _n = 0;
                    break;
                case 10 when _n >= 1:
                {
                    var index = (int)_s[--_n];
                    if (depth < MaxDepth && index >= 0 && index < font.Subrs.Length && font.Subrs[index] is { } sub)
                        Exec(sub, depth + 1);
                    break;
                }
                case 11:
                    return;
                case 14:
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

    private void Escape(int op)
    {
        switch (op)
        {
            case 6 when _n >= 5 && allowSeac:
                Seac(_s[0], _s[1], _s[2], (int)_s[3], (int)_s[4]);
                _n = 0;
                _done = true;
                break;
            case 7 when _n >= 4:
                _sbx = _s[0];
                _width = _s[2];
                _x = _sbx;
                _y = _s[1];
                _n = 0;
                break;
            case 12 when _n >= 2:
            {
                var d = _s[--_n];
                var a = _s[--_n];
                Push(d == 0 ? 0 : a / d);
                break;
            }
            case 16 when _n >= 2:
                CallOtherSubr();
                break;
            case 17:
                if (_ps.Count > 0)
                {
                    Push(_ps[^1]);
                    _ps.RemoveAt(_ps.Count - 1);
                }
                break;
            case 33 when _n >= 2:
                _x = _s[0];
                _y = _s[1];
                _n = 0;
                break;
            default:
                _n = 0;
                break;
        }
    }

    private void CallOtherSubr()
    {
        var which = (int)_s[--_n];
        var count = (int)_s[--_n];
        if (count < 0 || count > _n) count = _n;

        switch (which)
        {
            case 1:
                _flexing = true;
                _flex.Clear();
                _n -= count;
                break;
            case 2:
                if (_flexing) _flex.Add((_x, _y));
                _n -= count;
                break;
            case 0 when count >= 3:
            {
                var y = _s[_n - 1];
                var x = _s[_n - 2];
                _n -= count;
                _flexing = false;
                if (_flex.Count >= 7)
                {
                    Begin();
                    for (var k = 1; k <= 4; k += 3)
                        _out.CubicTo(_flex[k].X, _flex[k].Y, _flex[k + 1].X, _flex[k + 1].Y, _flex[k + 2].X, _flex[k + 2].Y);
                    _x = _flex[6].X;
                    _y = _flex[6].Y;
                }
                _ps.Add(y);
                _ps.Add(x);
                break;
            }
            default:
                // Hint replacement (3) and unknown routines hand their arguments back through pop.
                for (var i = 0; i < count; i++) _ps.Add(_s[--_n]);
                break;
        }
    }

    private void Seac(double asb, double adx, double ady, int baseCode, int accentCode)
    {
        Close();
        Append(baseCode, 0, 0);
        Append(accentCode, _sbx - asb + adx, ady);
    }

    private void Append(int code, double dx, double dy)
    {
        if (code is < 0 or > 255 || StandardNames.StandardEncoding[code] is not { } name) return;
        if (font.Run(name, false) is not { } glyph) return;
        foreach (var s in glyph.Outline.Segments)
            _out.Add(s.Op == OutlineOp.Close ? s : s with { X = s.X + dx, Y = s.Y + dy, X1 = s.X1 + dx, Y1 = s.Y1 + dy, X2 = s.X2 + dx, Y2 = s.Y2 + dy });
    }

    private void Push(double v)
    {
        if (_n < _s.Length) _s[_n++] = v;
        else _done = true;
    }

    private void Close()
    {
        if (!_open) return;
        _out.Close();
        _open = false;
    }

    private void Begin()
    {
        if (_open) return;
        _out.MoveTo(_x, _y);
        _open = true;
    }

    private void MoveTo(double dx, double dy)
    {
        _x += dx;
        _y += dy;
        if (_flexing) return;
        Close();
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
}
