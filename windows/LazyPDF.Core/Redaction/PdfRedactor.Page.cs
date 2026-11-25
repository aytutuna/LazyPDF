namespace LazyPDF.Core;

public sealed partial class PdfRedactor
{
    private const int MaxOpenQ = 1000;
    private const int MinNeedle = 3;

    // What is known of a marked page before anything is changed.
    private sealed record Plan(PdfPage Page, List<RedactionMark> Marks, List<MarkArea> Areas, int Hit, RedactionScan? Scan, bool Understood, HashSet<int> Reach,
        Dictionary<PdfStream, int> Entries);

    // What a viewer takes from a page dictionary (Table 30). The rest, the thumbnail and the private keys among it, is data the page has no use for.
    private static readonly string[] PageKeys =
        ["Type", "Parent", "Contents", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "BoxColorInfo", "Rotate", "UserUnit", "Group", "Annots", "B", "Dur", "Trans", "AA", "StructParents", "Tabs"];

    private Plan Examine(PdfDocument work, PdfPage page, List<RedactionMark> marks, ContentInterpreter interpreter, HashSet<string> needles)
    {
        var areas = marks.SelectMany(m => m.Quads).Select(MarkArea.Of).Where(a => a.IsUsable).ToList();
        int hit = AddNeedles(TextPage.Create(interpreter, page), areas, needles);
        var scan = new RedactionScan(areas);
        var walk = new RedactionWalk(work);
        bool understood;
        try
        {
            interpreter.Run(page, scan);
            understood = !interpreter.IsTruncated && !scan.Unhandled && walk.Page(page) && walk.Annotations(page);
        }
        catch (PdfReadException)
        {
            understood = false;
        }
        var reach = new HashSet<int>();
        RedactionObjects.Collect(work, page.Dictionary, reach, "B");
        return new Plan(page, marks, areas, hit, scan, understood, reach, walk.Entries);
    }

    // A picture or form that is cut where it meets a mark has to be shown nowhere else, on this page, on another marked one or by
    // an annotation: the cut is a copy, and every other use still names the original. A page with such a use becomes a picture.
    private static List<Plan> Reconcile(List<Plan> plans)
    {
        var cut = plans.Where(p => p.Understood).SelectMany(p => p.Scan!.Edited.Keys).ToHashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        return [.. plans.Select(p => p.Understood && cut.Any(s => p.Entries.GetValueOrDefault(s) != p.Scan!.Edited.GetValueOrDefault(s)) ? p with { Understood = false } : p)];
    }

    private PageRedaction RedactPage(PdfDocument work, Plan plan, RedactionOptions options, PdfDrawFont? font, ContentRewriter rewriter,
        HashSet<string> needles, HashSet<int> painted, List<int> flattened, out Dictionary<int, (int Total, int Removed)> tagged)
    {
        var (page, marks, areas) = (plan.Page, plan.Marks, plan.Areas);
        if (plan.Understood)
        {
            var scan = plan.Scan!;
            int wholeBefore = rewriter.WholeImages;
            byte[] content = RedactionResources.DropIdleFonts(rewriter.Rewrite(scan.Root, page.Contents(), page.Dictionary, page.Resources, false));
            string fontName = "";
            if (font is not null && marks.Any(m => !string.IsNullOrEmpty(m.OverlayText ?? options.OverlayText)))
            {
                fontName = ContentResources.Add(work, work.Dict(page.Dictionary, "Resources")!, "Font", font.Reference, "RdF");
            }
            content = Enclose(content, RedactionOverlay.Build(marks, options, font, fontName));
            // What was written is read again by the same rule; a page that fails it is a bug of the rewrite, not a reason to keep it.
            var probe = new RedactionWalk(work);
            bool followed = probe.Page(page, content);
            if (followed) RedactionResources.Rebuild(work, page.Dictionary, probe);
            var walk = new RedactionWalk(work);
            if (followed && walk.Page(page, content))
            {
                page.Dictionary["Contents"] = Store(work, content);
                foreach (var (key, _) in page.Dictionary.Entries.ToList())
                {
                    if (!PageKeys.Contains(key)) page.Dictionary.Remove(key);
                }
                tagged = scan.Marked;
                var (annotations, fields) = RemoveAnnotations(work, page, a => areas.Any(area => Geometry.Touches(a.Rect, area)), needles, false);
                KeepPainted(work, page, walk, painted);
                return new PageRedaction(page.Index, scan.Glyphs, scan.Images, scan.Paths, annotations, fields, 0, rewriter.WholeImages - wholeBefore);
            }
        }
        if (options.Renderer is null) throw new InvalidOperationException(RedactionText.NeedsPicture(page.Index));
        // Everything the page showed is gone, so every content item of its tags is.
        tagged = [];
        foreach (var stream in plan.Reach.Select(work.Get).OfType<PdfStream>()) rewriter.Replaced.Add(stream);
        var (removed, cleared) = RemoveAnnotations(work, page, a => plan.Areas.Any(area => Geometry.Touches(a.Rect, area)), needles, true);
        RedactionFlatten.Page(work, page, marks, options, font);
        KeepBoxes(work, page, painted);
        flattened.Add(page.Index);
        return new PageRedaction(page.Index, plan.Hit, 0, 0, removed, cleared);
    }

    internal static PdfReference Store(PdfDocument work, byte[] content) =>
        work.Add(new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") }, PdfFilterEncoders.Flate(content)));

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
    private static int AddNeedles(TextPage text, List<MarkArea> areas, HashSet<string> needles)
    {
        text.RequirePageContent();
        int hits = 0;
        foreach (var area in areas)
        {
            int start = -1;
            for (int i = 0; i <= text.Chars.Count; i++)
            {
                bool hit = i < text.Chars.Count && Geometry.GlyphMeets(Geometry.Corners(text.Chars[i].Quad), area);
                if (hit) hits++;
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
        return hits;
    }

    private static void AddNeedle(HashSet<string> needles, string? text)
    {
        if (text is not null && text.Count(c => !char.IsWhiteSpace(c)) >= MinNeedle) needles.Add(text.Trim());
    }

    // The annotations under a mark go with their fields, and what they said is looked for in the output. On a page that becomes a picture
    // every other annotation goes too, but a widget not under a mark only leaves its field when it was the field's last.
    private static (int Annotations, int Fields) RemoveAnnotations(PdfDocument work, PdfPage page, Func<PdfAnnotation, bool> meets, HashSet<string> needles, bool flat)
    {
        var all = PdfAnnotations.Read(work, page);
        var hit = all.Where(meets).ToList();
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
        var rest = new HashSet<PdfDictionary>(flat ? all.Where(a => !hit.Contains(a)).Select(a => a.Dictionary) : [], ReferenceEqualityComparer.Instance);
        foreach (var other in all.Where(a => a.Type == AnnotationType.Widget && rest.Contains(a.Dictionary)))
        {
            var form = PdfForm.Read(work);
            if (form.Fields.SelectMany(f => f.Widgets).FirstOrDefault(w => ReferenceEquals(w.Dictionary, other.Dictionary)) is not { } widget) continue;
            if (widget.Field.Widgets.Count <= 1) fields++;
            form.Remove(widget);
        }
        // A widget no field owns is only an annotation.
        var writer = new PdfAnnotationWriter(work);
        int removed = 0;
        foreach (var a in hit.Where(a => a.Type != AnnotationType.Widget || widgets.Contains(a.Dictionary)))
        {
            AddNeedle(needles, a.Contents);
            if (writer.Delete(a)) removed++;
        }
        foreach (var a in PdfAnnotations.Read(work, page).Where(k => rest.Contains(k.Dictionary)))
        {
            if (writer.Delete(a)) removed++;
        }
        return (removed, fields);
    }
}
