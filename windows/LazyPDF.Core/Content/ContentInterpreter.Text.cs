namespace LazyPDF.Core;

// Text positioning and showing (9.4).
public sealed partial class ContentInterpreter
{
    private void SyncText()
    {
        _context.TextMatrix = _tm;
        _context.TextLineMatrix = _tlm;
    }

    private void SetFont(ContentOperation op)
    {
        if (op.Operands.Count < 2 || op.Operands[^2] is not PdfName name || op.Operands[^1] is not PdfNumber size) return;
        _state.FontSize = size.Value;
        _state.Font = FindResource("Font", name.Value) is PdfDictionary dictionary ? PdfFont.Get(_doc, dictionary) : Fallback();
    }

    // A viewer draws text in a missing font with something plain; the metrics are Helvetica's.
    private PdfFont Fallback()
    {
        if (_fallbackFont is null)
        {
            var dictionary = new PdfDictionary();
            dictionary["Type"] = new PdfName("Font");
            dictionary["Subtype"] = new PdfName("Type1");
            dictionary["BaseFont"] = new PdfName("Helvetica");
            _fallbackFont = PdfFont.Get(_doc, dictionary);
        }
        return _fallbackFont;
    }

    private void MoveText(ContentOperation op)
    {
        Span<double> p = stackalloc double[6];
        switch (op.Operator)
        {
            case "Td" or "TD":
                if (!Numbers(op, p[..2])) return;
                if (op.Operator == "TD") _state.Leading = -p[1];
                _tlm = PdfMatrix.Translate(p[0], p[1]).Multiply(_tlm);
                _tm = _tlm;
                break;
            case "Tm":
                if (!Numbers(op, p)) return;
                _tm = _tlm = new PdfMatrix(p[0], p[1], p[2], p[3], p[4], p[5]);
                break;
            default:
                _tlm = PdfMatrix.Translate(0, -_state.Leading).Multiply(_tlm);
                _tm = _tlm;
                break;
        }
        SyncText();
    }

    private void ShowText(ContentOperation op)
    {
        var operands = op.Operands;
        if (operands.Count == 0) return;
        switch (op.Operator)
        {
            case "Tj":
                if (operands[^1] is PdfString s) Show(s, 0);
                break;
            case "'" or "\"":
                if (op.Operator == "\"" && operands.Count >= 3)
                {
                    if (operands[^3] is PdfNumber aw) _state.WordSpacing = aw.Value;
                    if (operands[^2] is PdfNumber ac) _state.CharSpacing = ac.Value;
                }
                _tlm = PdfMatrix.Translate(0, -_state.Leading).Multiply(_tlm);
                _tm = _tlm;
                SyncText();
                if (operands[^1] is PdfString line) Show(line, op.Operator == "\"" ? 1 : 0);
                break;
            default:
                if (operands[^1] is not PdfArray array) break;
                for (int i = 0; i < array.Items.Count; i++)
                {
                    if (--_budget < 0)
                    {
                        IsTruncated = true;
                        break;
                    }
                    if (array.Items[i] is PdfString text) Show(text, i);
                    else if (array.Items[i] is PdfNumber adjust && _state.Font is { } font)
                    {
                        double shift = -adjust.Value / 1000 * _state.FontSize;
                        _tm = (font.IsVertical ? PdfMatrix.Translate(0, shift) : PdfMatrix.Translate(shift * _state.HorizontalScale, 0)).Multiply(_tm);
                        SyncText();
                    }
                }
                break;
        }
    }

    private void Show(PdfString text, int element)
    {
        var state = _state;
        var font = state.Font ??= Fallback();
        var bytes = text.Bytes;
        var scale = new PdfMatrix(state.FontSize * state.HorizontalScale, 0, 0, state.FontSize, 0, state.Rise);
        for (int offset = 0; offset < bytes.Length;)
        {
            if (--_budget < 0)
            {
                IsTruncated = true;
                return;
            }
            int used = font.Read(bytes.AsSpan(offset), out var ch);
            if (used <= 0) return;
            double width = ch.Width / 1000;
            var trm = scale.Multiply(_tm).Multiply(state.Ctm);
            double advance;
            if (font.IsVertical)
            {
                trm = PdfMatrix.Translate(-ch.OriginX / 1000, -ch.OriginY / 1000).Multiply(trm);
                advance = ch.VerticalAdvance / 1000 * state.FontSize + state.CharSpacing + (ch.IsSpace ? state.WordSpacing : 0);
            }
            else
            {
                advance = (width * state.FontSize + state.CharSpacing + (ch.IsSpace ? state.WordSpacing : 0)) * state.HorizontalScale;
            }
            var box = trm.Transform(new PdfRect(0, font.Descent / 1000, width, font.Ascent / 1000));
            _visitor.ShowGlyph(_context, new GlyphInfo(ch, font, trm, box, advance, element, offset));
            _tm = (font.IsVertical ? PdfMatrix.Translate(0, advance) : PdfMatrix.Translate(advance, 0)).Multiply(_tm);
            SyncText();
            offset += used;
        }
    }
}
