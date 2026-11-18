namespace LazyPDF.Core;

/// <summary>Why an edit of the page content was refused; <see cref="AccessibilityText.ContentReason"/> gives the message. The keys of <see cref="TagRules"/> can come back from <see cref="StructureTree.TagSelection"/> too.</summary>
public static class TagContent
{
    public const string Truncated = "truncated";
    public const string NotInTree = "not-in-tree";
    public const string NotContent = "not-content";
    public const string FormContent = "form-content";
    public const string SharedStream = "shared-stream";
    public const string Unreadable = "unreadable-content";
    public const string NestedTagged = "nested-tagged";
    public const string PartialMarked = "partial-marked";
    public const string SplitOperation = "split-operation";
    public const string EmptySelection = "empty-selection";
    public const string TooLarge = "too-large";
}

/// <summary>The element a selection was tagged as, or why nothing changed.</summary>
public sealed record TagSelectionResult(StructElement? Element, string? Reason);

public sealed partial class StructureTree
{
    private static readonly string[] ArtifactKeys = ["Type", "BBox", "Attached", "Subtype"];

    /// <summary>
    /// Turns the marked content of <paramref name="kid"/> (a sequence, or an element with everything under it) into
    /// /Artifact in the page's content and takes it out of the tree; elements left without kids go too, but never a
    /// root. The content draws the same: an /MCID sequence becomes BMC /Artifact, or BDC /Artifact keeping its
    /// type, box, attached and subtype entries. Null when done, otherwise the reason and nothing is changed: content
    /// in a form XObject or in a stream another page draws, tagged content nested in the sequence or around it, or
    /// content that does not parse. Call <see cref="Write"/> afterwards. An object reference is not content.
    /// </summary>
    public string? MarkAsArtifact(StructKid kid)
    {
        if (IsTruncated) return TagContent.Truncated;
        if (kid is StructObject) return TagContent.NotContent;
        if (IndexIn(kid) < 0) return TagContent.NotInTree;
        var contents = kid is StructElement element
            ? Subtree(element).SelectMany(e => e.KidList.OfType<StructContent>()).ToList()
            : [(StructContent)kid];
        if (contents.Any(c => c.Stream is not null)) return TagContent.FormContent;

        var plans = new List<(PageStreams Page, List<ContentInsertion>[] Edits)>();
        foreach (var group in contents.Where(c => c.PageIndex >= 0 && c.PageIndex < _document.Pages.Count).GroupBy(c => c.PageIndex).OrderBy(g => g.Key))
        {
            var page = PageStreams.Load(_document, _document.Pages[group.Key]);
            if (page is null) return TagContent.Unreadable;
            if (page.IsShared) return TagContent.SharedStream;
            var ids = group.Select(c => c.Mcid).ToHashSet();
            var edits = page.NewEdits();
            var properties = page.Properties();
            foreach (var sequence in MarkedSequence.Scan(page, _document).Descendants().Where(s => s.Mcid is { } id && ids.Contains(id)))
            {
                bool around = false;
                for (var p = sequence.Parent; p is { Begin: >= 0 }; p = p.Parent) around |= p.Mcid is { } id && !ids.Contains(id);
                if (around || sequence.Descendants().Any(d => d.Mcid is { } id && !ids.Contains(id))) return TagContent.NestedTagged;
                var (stream, op) = page.At(sequence.Begin);
                edits[stream].Add(new ContentInsertion(op.Start, 1, ArtifactOpening(op, properties), op.End - op.Start));
            }
            plans.Add((page, edits));
        }
        foreach (var (page, edits) in plans) page.Save(edits);

        var parent = kid.Parent;
        Remove(kid);
        DropEmpty(parent);
        return null;
    }

    private static string ArtifactOpening(ContentOperation op, Func<string, PdfDictionary?> properties)
    {
        var dictionary = op.Operands.Count > 1 ? op.Operands[1] switch { PdfDictionary d => d, PdfName n => properties(n.Value), _ => null } : null;
        var kept = new PdfDictionary();
        foreach (string key in ArtifactKeys)
        {
            if (dictionary?[key] is { } value and not PdfReference) kept[key] = value;
        }
        return kept.Entries.Any() ? $"/Artifact {kept} BDC" : "/Artifact BMC";
    }

    // Keeps the other properties of the list (/ActualText, /Alt, /Lang, ...) so what assistive technology reads does not change.
    private static string Renumbered(ContentOperation op, string type, int mcid, Func<string, PdfDictionary?> properties)
    {
        var dictionary = op.Operands.Count > 1 ? op.Operands[1] switch { PdfDictionary d => d, PdfName n => properties(n.Value), _ => null } : null;
        bool artifact = op.Operands[0] is PdfName { Value: "Artifact" };
        var kept = new PdfDictionary();
        foreach (var (key, value) in dictionary?.Entries ?? [])
        {
            if (key == "MCID" || value is PdfReference || (artifact && ArtifactKeys.Contains(key))) continue;
            kept[key] = value;
        }
        kept["MCID"] = new PdfNumber(mcid);
        return $"{new PdfName(type)} {kept} BDC";
    }

    /// <summary>
    /// Tags the characters of <paramref name="ranges"/> (indexes into <see cref="TextPage.Chars"/> of
    /// <c>TextPage.Create(document, page)</c>, as the viewer's selection gives them) as a new element of
    /// <paramref name="type"/>; see <see cref="TagArea"/> for the rules.
    /// </summary>
    public TagSelectionResult TagSelection(int pageIndex, IReadOnlyList<TextRange> ranges, string type, StructElement? parent, int index = -1) =>
        TagContentOf(pageIndex, new Picked(ranges, null), type, parent, index);

    /// <summary>
    /// Tags what lies inside <paramref name="area"/> (page user space): the characters whose centers are in it and
    /// the pictures and forms that are wholly in it. The content gets /MCID sequences, the new element goes under
    /// <paramref name="parent"/> at <paramref name="index"/> (-1 for the end, counted after the content left its old
    /// place) and a tree with no root gets a Document one. Content that already has an /MCID in the tree moves to the
    /// new element when the whole sequence is picked; a sequence marked /Artifact or with an /MCID the tree does not
    /// name takes a new number the same way; anything else already marked is refused. A string cut by the selection,
    /// a partly covered sequence, content in a form XObject or a shared stream are refused with nothing changed (a
    /// reason of <see cref="TagContent"/> or <see cref="TagRules"/>). Call <see cref="Write"/> afterwards.
    /// </summary>
    public TagSelectionResult TagArea(int pageIndex, PdfRect area, string type, StructElement? parent, int index = -1) =>
        TagContentOf(pageIndex, new Picked(null, area), type, parent, index);

    private sealed record Picked(IReadOnlyList<TextRange>? Ranges, PdfRect? Area);

    private TagSelectionResult TagContentOf(int pageIndex, Picked picked, string type, StructElement? parent, int index)
    {
        static TagSelectionResult Refused(string reason) => new(null, reason);
        if (IsTruncated) return Refused(TagContent.Truncated);
        if (pageIndex < 0 || pageIndex >= _document.Pages.Count) return Refused(TagContent.NotInTree);
        var element = new StructElement(type) { PageIndex = pageIndex };
        if (ResolveNew(element, type, null) is not { } standard) return Refused(TagRules.Unmapped);
        if (parent is not null && IndexIn(parent) < 0) return Refused(TagContent.NotInTree);
        bool makeRoot = parent is null && _roots.Count == 0;
        if (TagRules.CanPlace(makeRoot ? "Document" : parent is null ? "" : StandardType(parent.Type), standard) is { } placement) return Refused(placement);
        if (TagRules.HasFixedKids(standard)) return Refused(TagRules.NoContent);
        if (standard == "Link") return Refused(TagRules.LinkObject);

        var page = PageStreams.Load(_document, _document.Pages[pageIndex]);
        if (page is null) return Refused(TagContent.Unreadable);
        if (page.IsShared) return Refused(TagContent.SharedStream);
        var (selected, required, why) = Pick(page, TextPage.Create(_document, _document.Pages[pageIndex]), picked);
        if (why is not null) return Refused(why);

        // Loose operations get a new sequence; a marked sequence the selection holds whole is claimed; one it holds in part is refused.
        var claims = new Dictionary<int, TagNode>();
        var claimed = new List<MarkedSequence>();
        var node = new TagNode(type);
        bool Whole(MarkedSequence s) => s.AllContent().Any(selected.Contains) && s.AllContent().All(o => selected.Contains(o) || !required(o));
        bool Walk(MarkedSequence sequence, bool inClaimed)
        {
            foreach (var child in sequence.Children)
            {
                if (child.IsClaimed && Whole(child)) claimed.Add(child);
                else if (!Walk(child, inClaimed || sequence.IsClaimed)) return false;
            }
            foreach (int op in sequence.Content.Where(selected.Contains))
            {
                if (inClaimed || sequence.IsClaimed) return false;
                claims[op] = node;
            }
            return true;
        }
        if (!Walk(MarkedSequence.Scan(page, _document), false)) return Refused(TagContent.PartialMarked);
        if (claims.Count == 0 && claimed.Count == 0) return Refused(TagContent.EmptySelection);

        var named = Contents.Where(c => c.PageIndex == pageIndex && c.Stream is null).GroupBy(c => c.Mcid).ToDictionary(g => g.Key, g => g.First());
        var used = ContentTagger.UsedMcids(page.Parsed, page.Properties(), _document);
        used.UnionWith(named.Keys);
        int next = 0;
        int Fresh()
        {
            while (used.Contains(next)) next++;
            return next++;
        }
        var planner = new ContentTagger(page.Parsed, claims, _ => Fresh(), artifacts: false);
        planner.Run();

        var edits = page.NewEdits();
        for (int s = 0; s < edits.Length; s++) edits[s].AddRange(planner.Insertions[s]);
        var order = planner.Sequences.Select(q => (q.Stream, q.Position, Content: new StructContent(pageIndex, q.Mcid))).ToList();
        var moved = new List<StructContent>();
        foreach (var sequence in claimed)
        {
            var (stream, op) = page.At(sequence.Begin);
            if (sequence.Mcid is { } id && named.TryGetValue(id, out var existing) && !moved.Contains(existing))
            {
                moved.Add(existing);
                order.Add((stream, op.Start, existing));
                continue;
            }
            int fresh = Fresh();
            edits[stream].Add(new ContentInsertion(op.Start, 1, Renumbered(op, type, fresh, page.Properties()), op.End - op.Start));
            order.Add((stream, op.Start, new StructContent(pageIndex, fresh)));
        }
        if (order.Count == 0) return Refused(TagContent.EmptySelection);
        int highest = order.Max(o => o.Content.Mcid);
        if (highest > MaxMcid || ParentSlots() + highest + 1 > MaxParentSlots) return Refused(TagContent.TooLarge);

        page.Save(edits);
        var oldParents = moved.Select(c => c.Parent).OfType<StructElement>().Distinct().ToList();
        foreach (var content in moved) Remove(content);
        if (makeRoot)
        {
            parent = new StructElement("Document");
            Add(null, parent);
        }
        Add(parent, element, index);
        foreach (var (_, _, content) in order.OrderBy(o => o.Stream).ThenBy(o => o.Position)) Add(element, content);
        foreach (var old in oldParents) DropEmpty(old);
        return new TagSelectionResult(element, null);
    }

    // The content operations the selection holds in full, and which operations a sequence needs picked to be held whole: a show
    // operation that has no characters (hidden text) is not one of them.
    private (HashSet<int> Selected, Func<int, bool> Required, string? Reason) Pick(PageStreams page, TextPage text, Picked picked)
    {
        var total = new Dictionary<int, int>();
        var count = new Dictionary<int, int>();
        var chars = text.Chars;
        foreach (var c in chars)
        {
            if (c.OperatorIndex >= 0 && c.Form is null) total[c.OperatorIndex] = total.GetValueOrDefault(c.OperatorIndex) + 1;
        }
        bool Required(int op) => page.At(op).Operation.Operator is "Do" or "BI" || total.ContainsKey(op);
        var selected = new HashSet<int>();
        if (picked.Ranges is { } ranges)
        {
            var seen = new HashSet<int>();
            foreach (var range in ranges)
            {
                for (int i = Math.Max(0, range.Start); i < Math.Min(range.End, chars.Count); i++)
                {
                    var c = chars[i];
                    if (c.OperatorIndex < 0 || !seen.Add(i)) continue;
                    if (c.Form is not null) return ([], Required, TagContent.FormContent);
                    count[c.OperatorIndex] = count.GetValueOrDefault(c.OperatorIndex) + 1;
                }
            }
        }
        else if (picked.Area is { } area)
        {
            foreach (var c in chars)
            {
                var (x, y) = c.Quad.Center;
                if (c.OperatorIndex >= 0 && c.Form is null && x >= area.Left && x <= area.Right && y >= area.Bottom && y <= area.Top)
                {
                    count[c.OperatorIndex] = count.GetValueOrDefault(c.OperatorIndex) + 1;
                }
            }
            var drawn = new Drawn();
            try
            {
                new ContentInterpreter(_document) { WalkPatterns = false }.Run(page.Page, drawn);
            }
            catch (PdfReadException)
            {
            }
            foreach (var (op, bounds, inline) in drawn.Items)
            {
                if (bounds.Left >= area.Left - 1 && bounds.Right <= area.Right + 1 && bounds.Bottom >= area.Bottom - 1 && bounds.Top <= area.Top + 1) selected.Add(op);
                else if (inline && !bounds.Intersect(area).IsEmpty) return ([], Required, TagContent.SplitOperation);
            }
        }
        foreach (var (op, n) in count)
        {
            if (n < total[op]) return ([], Required, TagContent.SplitOperation);
            selected.Add(op);
        }
        return (selected, Required, selected.Count == 0 ? TagContent.EmptySelection : null);
    }

    // The pictures and forms the page's own content draws, with where they are.
    private sealed class Drawn : ContentVisitor
    {
        public List<(int Operation, PdfRect Bounds, bool Inline)> Items { get; } = [];

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (context.Forms.Count == 0) Items.Add((context.OperatorIndex, image.Bounds, image.Inline is not null));
        }

        public override void BeginForm(ContentContext context, FormInfo form)
        {
            if (!form.IsPattern && context.Forms.Count == 1) Items.Add((context.OperatorIndex, form.Bounds, false));
        }
    }

    private static IEnumerable<StructElement> Subtree(StructElement element)
    {
        var stack = new Stack<StructElement>([element]);
        while (stack.Count > 0)
        {
            var e = stack.Pop();
            yield return e;
            foreach (var child in e.Children.Reverse()) stack.Push(child);
        }
    }

    private void DropEmpty(StructElement? start)
    {
        for (var e = start; e is { Parent: not null } && e.KidList.Count == 0;)
        {
            var parent = e.Parent;
            Remove(e);
            e = parent;
        }
    }
}
