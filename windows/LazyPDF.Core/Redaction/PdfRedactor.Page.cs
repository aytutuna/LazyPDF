namespace LazyPDF.Core;

public sealed partial class PdfRedactor
{
    private const int MaxOpenQ = 1000;
    private const int MinNeedle = 3;

    private PageRedaction RedactPage(PdfDocument work, PdfPage page, List<RedactionMark> marks, RedactionOptions options, PdfDrawFont? font,
        ContentRewriter rewriter, ContentInterpreter interpreter, HashSet<string> needles, HashSet<object> dropped, out Dictionary<int, (int Total, int Removed)> tagged)
    {
        var areas = marks.SelectMany(m => m.Quads).Select(MarkArea.Of).Where(a => a.IsUsable).ToList();
        AddNeedles(TextPage.Create(interpreter, page), areas, needles);
        var scan = new RedactionScan(areas, page.Resources);
        interpreter.Run(page, scan);
        if (interpreter.IsTruncated || RedactionLimits.Exceeded(ContentParser.Parse(page.Contents()))) throw new InvalidOperationException(RedactionText.TooBig);
        dropped.UnionWith(scan.Dropped);
        tagged = scan.Marked;

        byte[] content = rewriter.Rewrite(scan.Root, page.Contents(), page.Dictionary, page.Resources, false);
        string fontName = "";
        if (font is not null && marks.Any(m => !string.IsNullOrEmpty(m.OverlayText ?? options.OverlayText)))
        {
            fontName = ContentResources.Add(work, work.Dict(page.Dictionary, "Resources")!, "Font", font.Reference, "RdF");
        }
        content = Enclose(content, RedactionOverlay.Build(marks, options, font, fontName));
        var stream = new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") }, PdfFilterEncoders.Flate(content));
        page.Dictionary["Contents"] = work.Add(stream);
        foreach (string key in (ReadOnlySpan<string>)["Thumb", "PieceInfo", "Metadata"]) page.Dictionary.Remove(key);

        var (annotations, fields) = RemoveAnnotations(work, page, areas, needles);
        return new PageRedaction(page.Index, scan.Glyphs, scan.Images, scan.Paths, annotations, fields);
    }

    // The overlay goes after the page in a clean state, whatever the page leaves open (ISO 32000-1 8.4.2).
    private static byte[] Enclose(byte[] content, byte[] overlay)
    {
        int depth = 0, lowest = 0, marked = 0;
        bool text = false;
        var operations = ContentParser.Parse(content);
        // Operands with no operator after them, or a string never closed, would swallow what follows.
        content = content[..(operations.Count > 0 ? operations[^1].End : 0)];
        foreach (var op in operations)
        {
            switch (op.Operator)
            {
                case "q": depth++; break;
                case "Q": lowest = Math.Min(lowest, --depth); break;
                case "BT": text = true; break;
                case "ET": text = false; break;
                case "BMC" or "BDC": marked++; break;
                case "EMC": marked = Math.Max(0, marked - 1); break;
            }
        }
        int opened = Math.Clamp(1 - lowest, 1, MaxOpenQ);
        var head = new ContentWriter();
        for (int i = 0; i < opened; i++) head.Save();
        var tail = new ContentWriter();
        if (text) tail.EndText();
        for (int i = 0; i < Math.Min(marked, MaxOpenQ); i++) tail.EndMarked();
        for (int i = Math.Clamp(opened + depth, 0, MaxOpenQ); i > 0; i--) tail.Restore();
        return [.. head.ToArray(), .. content, (byte)'\n', .. tail.ToArray(), .. overlay];
    }

    // The words of the page under each mark, to look for in places the marks do not reach.
    private static void AddNeedles(TextPage text, List<MarkArea> areas, HashSet<string> needles)
    {
        text.RequirePageContent();
        foreach (var area in areas)
        {
            int start = -1;
            for (int i = 0; i <= text.Chars.Count; i++)
            {
                bool hit = i < text.Chars.Count && Geometry.GlyphMeets(Geometry.Corners(text.Chars[i].Quad), area);
                if (hit && start < 0)
                {
                    start = i;
                    continue;
                }
                if (hit || start < 0) continue;
                foreach (string part in text.GetText(new TextRange(start, i)).Split('\n', '\t'))
                {
                    string phrase = string.Join(' ', part.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                    if (phrase.Count(c => !char.IsWhiteSpace(c)) >= MinNeedle) needles.Add(phrase);
                }
                start = -1;
            }
        }
    }

    private static void AddNeedle(HashSet<string> needles, string? text)
    {
        if (text is not null && text.Count(c => !char.IsWhiteSpace(c)) >= MinNeedle) needles.Add(text.Trim());
    }

    private static (int Annotations, int Fields) RemoveAnnotations(PdfDocument work, PdfPage page, List<MarkArea> areas, HashSet<string> needles)
    {
        var hit = PdfAnnotations.Read(work, page).Where(a => areas.Any(area => Geometry.Meets(a.Rect, area))).ToList();
        var widgets = new HashSet<PdfDictionary>(hit.Where(a => a.Type == AnnotationType.Widget).Select(a => a.Dictionary), ReferenceEqualityComparer.Instance);
        int fields = 0;
        while (widgets.Count > 0)
        {
            var form = PdfForm.Read(work);
            var field = form.Fields.FirstOrDefault(f => f.Widgets.Any(w => widgets.Contains(w.Dictionary)));
            if (field is null) break;
            foreach (var widget in field.Widgets) widgets.Remove(widget.Dictionary);
            AddNeedle(needles, field.Value);
            form.Remove(field);
            fields++;
        }
        // A widget no field owns is only an annotation.
        var writer = new PdfAnnotationWriter(work);
        int removed = 0;
        foreach (var a in hit.Where(a => a.Type != AnnotationType.Widget || widgets.Contains(a.Dictionary)))
        {
            AddNeedle(needles, a.Contents);
            if (writer.Delete(a)) removed++;
        }
        return (removed, fields);
    }
}
