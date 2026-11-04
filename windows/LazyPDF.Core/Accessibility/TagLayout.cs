namespace LazyPDF.Core;

/// <summary>
/// Reads the layout <see cref="TextPage"/> found and decides the elements of one page: headings by
/// size and weight, lists by their markers, tables where every row has the same cells, paragraphs,
/// figures for images. Header, footer and page number lines are left out, which makes them artifacts.
/// </summary>
internal sealed class TagLayout
{
    private const int MaxHeadingLines = 4;
    private const int MaxBoldHeadingLines = 2;

    private readonly PdfDocument _document;
    private readonly PdfPage _page;
    private readonly TextPage _text;
    private readonly TagScan _scan;
    private readonly TagStats _stats;
    private readonly PageGeometry _geometry;
    private readonly TagPage _result;

    private TagLayout(PdfDocument document, PdfPage page, TextPage text, TagScan scan, TagStats stats)
    {
        _document = document;
        _page = page;
        _text = text;
        _scan = scan;
        _stats = stats;
        _geometry = new PageGeometry(page);
        _result = new TagPage(page.Index);
    }

    public static TagPage Build(PdfDocument document, PdfPage page, TextPage text, TagScan scan, TagStats stats)
    {
        var layout = new TagLayout(document, page, text, scan, stats);
        foreach (var block in text.Blocks)
        {
            var lines = layout.LinesOf(block);
            if (lines.Count == 0) continue;
            if (block.IsTable && layout.TryTable(lines) is { } table) layout._result.Nodes.Add(table);
            else layout.AddText(lines);
        }
        layout.AddFigures();
        layout.AddAnnotations();
        return layout._result;
    }

    private List<TagLine> LinesOf(TextBlock block)
    {
        var lines = new List<TagLine>();
        for (int i = block.Lines.Start; i < block.Lines.End; i++)
        {
            var line = new TagLine(_text, _text.Lines[i], _geometry);
            if (!IsRunning(line) && !IsArtifact(line)) lines.Add(line);
        }
        return lines;
    }

    private bool IsArtifact(TagLine line)
    {
        int marked = 0, count = 0;
        for (int i = line.Range.Start; i < line.Range.End; i++)
        {
            count++;
            if (_text.Chars[i].IsArtifact) marked++;
        }
        return count > 0 && marked * 2 >= count;
    }

    private bool IsRunning(TagLine line)
    {
        if (TagText.Band(line, _geometry.Height) is not { } band) return false;
        if (TagText.IsPageNumber(line.Text)) return true;
        return TagText.Signature(line.Text) is { } signature && _stats.Repeated.Contains(band + "|" + signature);
    }

    private TagNode? TryTable(List<TagLine> lines)
    {
        var rows = new List<List<TagLine>>();
        foreach (var line in lines)
        {
            if (rows.Count == 0 || line.Before != TextBreak.Tab) rows.Add([line]);
            else rows[^1].Add(line);
        }
        if (rows.Count < 2 || rows[0].Count < 2 || rows.Any(r => r.Count != rows[0].Count)) return null;
        if (rows.All(r => TagText.IsLoneMarker(r[0].Text))) return null;

        var table = new TagNode("Table");
        foreach (var row in rows)
        {
            var tr = new TagNode("TR");
            foreach (var cell in row)
            {
                var node = new TagNode(ReferenceEquals(row, rows[0]) ? "TH" : "TD") { Area = cell.Rect };
                node.Operations.AddRange(OperationsOf(cell.Range));
                tr.Children.Add(node);
            }
            tr.Area = row.Select(c => c.Rect).Aggregate(Union);
            table.Children.Add(tr);
        }
        table.Area = rows.SelectMany(r => r).Select(l => l.Rect).Aggregate(Union);
        return table;
    }

    private void AddText(List<TagLine> source)
    {
        var lines = MergeMarkers(source);
        bool vertical = lines.Any(l => l.IsVertical);
        int i = 0;
        while (i < lines.Count)
        {
            if (!vertical && TryHeading(lines, i) is { } heading)
            {
                _result.Nodes.Add(heading.Node);
                i = heading.Next;
                continue;
            }
            if (!vertical && TryList(lines, i) is { } list)
            {
                _result.Nodes.Add(list.Node);
                i = list.Next;
                continue;
            }
            int end = i + 1;
            while (end < lines.Count && (vertical || ContinuesParagraph(lines, end)))
            {
                end++;
            }
            _result.Nodes.Add(Paragraph(lines, i, end));
            i = end;
        }
    }

    private static List<TagLine> MergeMarkers(List<TagLine> lines)
    {
        var merged = new List<TagLine>();
        for (int i = 0; i < lines.Count; i++)
        {
            if (i + 1 < lines.Count && TagText.IsLoneMarker(lines[i].Text) && lines[i + 1].Before == TextBreak.Tab)
            {
                merged.Add(TagLine.Join(lines[i], lines[i + 1]));
                i++;
            }
            else
            {
                merged.Add(lines[i]);
            }
        }
        return merged;
    }

    private bool ContinuesParagraph(List<TagLine> lines, int at)
    {
        var line = lines[at];
        return Gap(lines[at - 1], line) <= 0.5 * Math.Max(lines[at - 1].Size, line.Size)
            && LookOf(line) is null && TagText.MarkerOf(line.Text) is null;
    }

    private static double Gap(TagLine above, TagLine below) => below.Rect.Y - (above.Rect.Y + above.Rect.Height);

    private HeadingLook? LookOf(TagLine line)
    {
        if (line.Size <= 0 || line.Text.Length > 150 || line.Text.Count(char.IsLetter) < 2) return null;
        if (line.Size >= _stats.BodySize * 1.15) return new HeadingLook(line.Size, line.Bold);
        if (line.Bold && !_stats.BodyBold && line.Size >= _stats.BodySize - 0.25 && line.Text.Length <= 100) return new HeadingLook(line.Size, true);
        return null;
    }

    private (TagNode Node, int Next)? TryHeading(List<TagLine> lines, int at)
    {
        if (LookOf(lines[at]) is not { } look) return null;
        int end = at + 1;
        while (end < lines.Count && LookOf(lines[end]) == look && Gap(lines[end - 1], lines[end]) <= 0.9 * look.Size) end++;
        bool bodySized = look.Size < _stats.BodySize * 1.15;
        if (end - at > (bodySized ? MaxBoldHeadingLines : MaxHeadingLines)) return null;
        if (bodySized && lines[end - 1].Text.TrimEnd() is [.., ('.' or ',' or ';')]) return null;

        var node = new TagNode("H") { Heading = look };
        Fill(node, lines, at, end);
        return (node, end);
    }

    private (TagNode Node, int Next)? TryList(List<TagLine> lines, int at)
    {
        if (TagText.MarkerOf(lines[at].Text) is not { } first || LookOf(lines[at]) is not null) return null;
        var items = new List<(int Start, int End, ListMarker Marker)>();
        int i = at;
        while (i < lines.Count && TagText.MarkerOf(lines[i].Text) is { } marker && marker.Numbered == first.Numbered && LookOf(lines[i]) is null)
        {
            int end = i + 1;
            while (end < lines.Count && TagText.MarkerOf(lines[end].Text) is null && LookOf(lines[end]) is null
                && Gap(lines[end - 1], lines[end]) <= 0.5 * lines[end].Size && lines[end].Rect.X >= lines[i].Rect.X - 0.5 * lines[end].Size)
            {
                end++;
            }
            items.Add((i, end, marker));
            i = end;
        }
        if (items.Count < 2) return null;

        var list = new TagNode("L");
        foreach (var (start, end, marker) in items)
        {
            var item = new TagNode("LI");
            var label = SplitMarker(lines[start], marker.Length);
            var labelOperations = OperationsOf(label.Label);
            var body = new TagNode("LBody");
            body.Operations.AddRange(OperationsOf(new TextRange(label.BodyStart, lines[end - 1].Range.End)));
            if (labelOperations.Count > 0 && !labelOperations.Intersect(body.Operations).Any())
            {
                var lbl = new TagNode("Lbl") { Area = lines[start].Rect };
                lbl.Operations.AddRange(labelOperations);
                item.Children.Add(lbl);
            }
            else
            {
                body.Operations.InsertRange(0, labelOperations.Except(body.Operations));
            }
            body.Area = Enumerable.Range(start, end - start).Select(n => lines[n].Rect).Aggregate(Union);
            item.Children.Add(body);
            item.Area = body.Area;
            list.Children.Add(item);
        }
        list.Area = list.Children.Select(c => c.Area).Aggregate(Union);
        return (list, i);
    }

    private (TextRange Label, int BodyStart) SplitMarker(TagLine line, int length)
    {
        int i = line.Range.Start;
        while (i < line.Range.End && _text.Chars[i].IsSpace) i++;
        int start = i, taken = 0;
        while (i < line.Range.End && taken < length)
        {
            taken += Math.Max(_text.Chars[i].Text.Length, 1);
            i++;
        }
        int body = i;
        while (body < line.Range.End && _text.Chars[body].IsSpace) body++;
        return (new TextRange(start, i), body);
    }

    private TagNode Paragraph(List<TagLine> lines, int start, int end)
    {
        var node = new TagNode("P");
        Fill(node, lines, start, end);
        return node;
    }

    private void Fill(TagNode node, List<TagLine> lines, int start, int end)
    {
        node.Operations.AddRange(OperationsOf(new TextRange(lines[start].Range.Start, lines[end - 1].Range.End)));
        node.Area = Enumerable.Range(start, end - start).Select(n => lines[n].Rect).Aggregate(Union);
    }

    private List<int> OperationsOf(TextRange range)
    {
        var found = new List<int>();
        var seen = new HashSet<int>();
        for (int i = range.Start; i < range.End && i < _text.Chars.Count; i++)
        {
            var c = _text.Chars[i];
            if (c.IsArtifact || c.OperatorIndex < 0) continue;
            int operation = c.OperatorIndex;
            if (c.Form is not null)
            {
                if (!_scan.FormOperations.TryGetValue(c.Form, out operation) || _scan.Repeated.Contains(c.Form)) continue;
            }
            if (seen.Add(operation)) found.Add(operation);
        }
        return found;
    }

    private void AddFigures()
    {
        var done = new HashSet<int>();
        foreach (var image in _scan.Images)
        {
            if (image.Operation < 0 || !done.Add(image.Operation)) continue;
            var area = _geometry.ToDisplay(image.Bounds);
            if (area.Width < 2 || area.Height < 2) continue;
            var figure = new TagNode("Figure") { Area = area };
            figure.Operations.Add(image.Operation);
            int at = _result.Nodes.FindIndex(n => n.Area.Y > area.Y + 1 && Overlap(n.Area, area));
            _result.Nodes.Insert(at < 0 ? _result.Nodes.Count : at, figure);
        }
    }

    private static bool Overlap(DisplayRect a, DisplayRect b)
    {
        double shared = Math.Min(a.X + a.Width, b.X + b.Width) - Math.Max(a.X, b.X);
        return shared > 0.3 * Math.Min(a.Width, b.Width);
    }

    private void AddAnnotations()
    {
        if (_document.Array(_page.Dictionary, "Annots") is not { } annots) return;
        foreach (var item in annots.Items.Take(5000))
        {
            if (item is not PdfReference reference || _document.Resolve(item) is not PdfDictionary d) continue;
            string subtype = _document.Name(d, "Subtype") ?? "";
            if (subtype is "Popup" or "TrapNet" or "PrinterMark" or "Watermark" || ((_document.Integer(d, "F") ?? 0) & 2) != 0) continue;
            _result.Annotations.Add(new TagAnnotation(reference, subtype, subtype == "Link" ? TextUnder(d) : ""));
        }
    }

    private string TextUnder(PdfDictionary annotation)
    {
        if (_document.Rect(annotation, "Rect") is not { } rect) return "";
        var found = new System.Text.StringBuilder();
        foreach (var c in _text.Chars)
        {
            var center = c.Quad.Bounds;
            double x = (center.Left + center.Right) / 2, y = (center.Bottom + center.Top) / 2;
            if (x >= rect.Left && x <= rect.Right && y >= rect.Bottom && y <= rect.Top) found.Append(c.Text);
            if (found.Length > 300) break;
        }
        return string.Join(' ', found.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    private static DisplayRect Union(DisplayRect a, DisplayRect b)
    {
        double x = Math.Min(a.X, b.X), y = Math.Min(a.Y, b.Y);
        return new DisplayRect(x, y, Math.Max(a.X + a.Width, b.X + b.Width) - x, Math.Max(a.Y + a.Height, b.Y + b.Height) - y);
    }
}
