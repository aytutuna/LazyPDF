using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

internal enum TagCommand { MoveUp, MoveDown, Indent, Outdent, Delete, DeleteAsArtifact, MarkAsArtifact, MakeHeaderRow }

internal enum DropZone { Before, Into, After }

internal enum TagResult { Done, Unchanged, Refused, Gone, Failed }

internal readonly record struct TagOutcome(TagResult Result, string? Reason = null);

/// <summary>The fields of the element editor.</summary>
internal sealed record TagProperties(string Type, string Title, string Alt, string ActualText, string Lang, TableAttributes? Table);

/// <summary>
/// Where a node of the tag tree is, as the steps from the roots, and what it was. The tree on the screen is read from
/// a copy, so a command finds its node again in the open document's own tree and only goes on when the same node is there.
/// </summary>
internal sealed record TagPath(string Steps, string Key)
{
    public static TagPath Of(StructureTree tree, StructKid kid)
    {
        var steps = new List<int>();
        for (var k = kid; k is not null; k = k.Parent) steps.Add(IndexOf(Siblings(tree, k), k));
        steps.Reverse();
        return new TagPath(string.Join('/', steps), KeyOf(kid));
    }

    /// <summary>What names a node across reads of the file: the object of an element, the page and number of marked content.</summary>
    public static string KeyOf(StructKid kid) => kid switch
    {
        StructElement e => e.Reference is { } r ? "E" + r.Number : "T" + e.Type,
        StructContent c => $"C{c.PageIndex}.{c.Mcid}.{c.Stream?.Number}",
        StructObject o => "O" + o.Target.Number,
        _ => "",
    };

    public StructKid? Find(StructureTree tree)
    {
        StructKid? kid = null;
        foreach (string step in Steps.Split('/'))
        {
            if (kid is not null and not StructElement) return null;
            var list = kid is StructElement parent ? parent.Kids : tree.Roots;
            if (!int.TryParse(step, out int at) || at < 0 || at >= list.Count) return null;
            kid = list[at];
        }
        return kid is not null && KeyOf(kid) == Key ? kid : null;
    }

    public static IReadOnlyList<StructKid> Siblings(StructureTree tree, StructKid kid) => kid.Parent is { } parent ? parent.Kids : tree.Roots;

    public static int IndexOf(IReadOnlyList<StructKid> list, StructKid kid)
    {
        for (int i = 0; i < list.Count; i++)
        {
            if (ReferenceEquals(list[i], kid)) return i;
        }
        return -1;
    }
}

/// <summary>What the tag tree editor changes in a document, kept apart from the controls.</summary>
internal static class TagEdits
{
    private static readonly string[] Common =
    [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "H", "H1", "H2", "H3", "H4", "H5", "H6", "P", "L", "LI", "Lbl", "LBody",
        "Table", "THead", "TBody", "TFoot", "TR", "TH", "TD", "Caption", "Figure", "Formula", "Span", "Link", "Note", "Quote", "Code",
        "Reference", "BibEntry", "TOC", "TOCI", "Index", "Form", "NonStruct", "Private",
    ];

    /// <summary>The types the editor offers: the standard ones, then the types of the file's role map.</summary>
    public static IReadOnlyList<string> Types(StructureTree tree) => [.. Common, .. tree.RoleMap.Keys.Where(k => !Common.Contains(k)).Order(StringComparer.Ordinal)];

    /// <summary>Why nothing may be changed in the tags of this file; null when it may.</summary>
    public static string? ReadOnlyReason(PdfDocument document, StructureTree? tree)
    {
        if (document.IsEncrypted) return Loc.T("The file is encrypted, so its tags cannot be changed here.");
        if (ChangeGate.Refusal(document) is { } problem) return problem.Text;
        if (tree is { IsTruncated: true }) return Loc.T("The tree is too large to edit, so it is read-only.");
        return null;
    }

    public static string Label(TagCommand command) => command switch
    {
        TagCommand.MoveUp => Loc.T("Move tag up"),
        TagCommand.MoveDown => Loc.T("Move tag down"),
        TagCommand.Indent => Loc.T("Indent tag"),
        TagCommand.Outdent => Loc.T("Outdent tag"),
        TagCommand.Delete => Loc.T("Delete tag"),
        TagCommand.DeleteAsArtifact => Loc.T("Delete tag as artifact"),
        TagCommand.MarkAsArtifact => Loc.T("Mark as artifact"),
        _ => Loc.T("Make header row"),
    };

    /// <summary>Whether the command means anything for the node where it stands; false greys its button.</summary>
    public static bool Applies(StructureTree tree, StructKid kid, TagCommand command)
    {
        var siblings = TagPath.Siblings(tree, kid);
        int at = TagPath.IndexOf(siblings, kid);
        if (at < 0) return false;
        return command switch
        {
            TagCommand.MoveUp => at > 0,
            TagCommand.MoveDown => at < siblings.Count - 1,
            TagCommand.Indent => kid is StructElement && at > 0 && siblings[at - 1] is StructElement,
            TagCommand.Outdent => kid is StructElement && kid.Parent is not null,
            TagCommand.Delete or TagCommand.DeleteAsArtifact => kid is StructElement,
            TagCommand.MarkAsArtifact => kid is StructContent,
            _ => kid is StructElement row && tree.StandardType(row.Type) == "TR",
        };
    }

    /// <summary>Why the command would break the structure; null when it fits. Moves inside one parent never do.</summary>
    public static string? Refusal(StructureTree tree, StructKid kid, TagCommand command)
    {
        var siblings = TagPath.Siblings(tree, kid);
        int at = TagPath.IndexOf(siblings, kid);
        switch (command)
        {
            case TagCommand.Indent when at > 0 && siblings[at - 1] is StructElement previous:
                return PlaceRefusal(tree, kid, previous);
            case TagCommand.Outdent when kid.Parent is { } parent:
                return PlaceRefusal(tree, kid, parent.Parent);
            case TagCommand.Delete when kid is StructElement element:
                foreach (var inner in element.Kids)
                {
                    if (PlaceRefusal(tree, inner, element.Parent) is { } reason) return reason;
                }
                return null;
            default:
                return null;
        }
    }

    /// <summary>Why <paramref name="kid"/> may not sit under <paramref name="parent"/> (null: the top of the tree); null when it may.</summary>
    public static string? PlaceRefusal(StructureTree tree, StructKid kid, StructElement? parent)
    {
        for (var p = parent; p is not null; p = p.Parent)
        {
            if (ReferenceEquals(p, kid)) return Loc.T("An element cannot go into itself.");
        }
        if (kid is StructElement element) return Reason(TagRules.CanPlace(tree, parent, element));
        if (parent is null) return Loc.T("Only an element can sit at the root.");
        return TagRules.HasFixedKids(tree.StandardType(parent.Type)) ? Reason(TagRules.NoContent) : null;
    }

    /// <summary>Why <paramref name="element"/> may not take <paramref name="type"/>; null when it may.</summary>
    public static string? TypeRefusal(StructureTree tree, StructElement element, string type) =>
        type.Trim().Length == 0 ? Loc.T("The type is empty.") : Reason(TagRules.CanSetType(tree, element, type.Trim()));

    private static string? Reason(string? key) => key is null ? null : AccessibilityText.PlacementReason(key);

    /// <summary>
    /// Runs one edit on the open document's own tree as a single undo step: reads the tree again, finds the node
    /// <paramref name="path"/> names (none when it is null), lets <paramref name="edit"/> change it, writes the tree
    /// and commits. An edit answers null or the reason it was refused, and a refusal changes nothing.
    /// </summary>
    public static TagOutcome Apply(DocumentTab tab, TagPath? path, string label, Func<StructureTree, StructKid?, string?> edit)
    {
        var document = tab.Document;
        try
        {
            var tree = StructureTree.Read(document);
            if (tree is null) return new(TagResult.Gone);
            if (ReadOnlyReason(document, tree) is { } why) return new(TagResult.Refused, why);
            StructKid? kid = null;
            if (path is not null && (kid = path.Find(tree)) is null) return new(TagResult.Gone);
            if (edit(tree, kid) is { } reason)
            {
                tab.Session.Discard();
                return new(TagResult.Refused, reason);
            }
            tree.Write(document);
            return new(tab.Commit(label) ? TagResult.Done : TagResult.Unchanged);
        }
        catch (Exception error) when (error is InvalidOperationException or PdfReadException)
        {
            tab.Session.Discard();
            return new(TagResult.Failed);
        }
        catch
        {
            tab.Session.Discard();
            throw;
        }
    }

    public static string? Run(StructureTree tree, StructKid kid, TagCommand command)
    {
        if (!Applies(tree, kid, command)) return Loc.T("That cannot be done to this tag.");
        if (Refusal(tree, kid, command) is { } reason) return reason;
        bool done = command switch
        {
            TagCommand.MoveUp => tree.MoveUp(kid),
            TagCommand.MoveDown => tree.MoveDown(kid),
            TagCommand.Indent => tree.Indent((StructElement)kid),
            TagCommand.Outdent => tree.Outdent((StructElement)kid),
            TagCommand.Delete => tree.Unwrap((StructElement)kid),
            TagCommand.MakeHeaderRow => tree.MakeHeaderRow((StructElement)kid) > 0,
            _ => true,
        };
        if (command is TagCommand.DeleteAsArtifact or TagCommand.MarkAsArtifact)
            return tree.MarkAsArtifact(kid) is { } key ? AccessibilityText.ContentReason(key) : null;
        return done ? null : Loc.T("That cannot be done to this tag.");
    }

    /// <summary>The place a drop on <paramref name="target"/> gives <paramref name="kid"/>; the index counts after the kid left its old place.</summary>
    public static (StructElement? Parent, int Index) DropAt(StructureTree tree, StructKid kid, StructKid target, DropZone zone)
    {
        if (zone == DropZone.Into && target is StructElement into) return (into, -1);
        var siblings = TagPath.Siblings(tree, target).Where(k => !ReferenceEquals(k, kid)).ToList();
        int at = siblings.FindIndex(k => ReferenceEquals(k, target));
        return (target.Parent, zone == DropZone.Before ? at : at + 1);
    }

    /// <summary>Why a drop would break the structure, or null; <paramref name="apply"/> moves the node when it would not.</summary>
    public static string? Drop(StructureTree tree, StructKid kid, StructKid target, DropZone zone, bool apply)
    {
        if (ReferenceEquals(kid, target)) return Loc.T("That cannot be done to this tag.");
        var (parent, index) = DropAt(tree, kid, target, zone);
        if (PlaceRefusal(tree, kid, parent) is { } reason) return reason;
        if (kid is StructObject && kid.Parent is { } from && !ReferenceEquals(from, parent) && tree.StandardType(from.Type) == "Link"
            && from.Kids.Count(k => k is StructObject) == 1)
            return Reason(TagRules.LinkObject);
        if (apply) tree.Move(kid, parent, index);
        return null;
    }

    public static string? SetProperties(StructureTree tree, StructElement element, TagProperties p)
    {
        string type = p.Type.Trim();
        string lang = p.Lang.Trim();
        if (lang.Length > 0 && !AccessibilityEdits.IsLanguageTag(lang)) return Loc.T("Write the language as a tag such as en-US or tr-TR.");
        if (type != element.Type)
        {
            if (TypeRefusal(tree, element, type) is { } reason) return reason;
            tree.SetType(element, type);
        }
        element.Title = Text(p.Title.Trim());
        element.Alt = Text(p.Alt.Trim());
        element.ActualText = Text(p.ActualText);
        element.Lang = Text(lang);
        if (p.Table is { } table && tree.StandardType(element.Type) is "TH" or "TD" && !ShowsAlready(tree.GetTableAttributes(element), table))
            tree.SetTableAttributes(element, table);
        return null;
    }

    // The editor shows the header IDs as one text, so IDs with a comma in them come back split; a cell whose fields still show what it has is left as it is.
    private static bool ShowsAlready(TableAttributes current, TableAttributes fields)
    {
        var shown = Ids(string.Join(", ", current.Headers ?? []));
        return current.Scope == fields.Scope && current.RowSpan == fields.RowSpan && current.ColSpan == fields.ColSpan
            && shown.SequenceEqual(fields.Headers ?? []);
    }

    private static string[] Ids(string headers) => headers.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string? Text(string text) => text.Length > 0 ? text : null;

    /// <summary>The table attributes the editor's four fields stand for; null with the reason when a span is not a whole number from 1.</summary>
    public static TableAttributes? TableOf(string scope, string rowSpan, string colSpan, string headers, out string? problem)
    {
        string? bad = null;
        int? Span(string text)
        {
            text = text.Trim();
            if (text.Length == 0) return null;
            if (int.TryParse(text, out int n) && n >= 1) return n;
            bad = Loc.T("A span is a whole number from 1.");
            return null;
        }
        var rows = Span(rowSpan);
        var columns = Span(colSpan);
        problem = bad;
        if (bad is not null) return null;
        TableScope? chosen = scope switch { "Row" => TableScope.Row, "Column" => TableScope.Column, "Both" => TableScope.Both, _ => null };
        return new TableAttributes(chosen, Ids(headers), rows, columns);
    }

    /// <summary>The element the new tag goes under: the node itself, or the element holding it.</summary>
    private static StructElement? ParentFor(StructKid? kid) => kid as StructElement ?? kid?.Parent;

    public static string? TagSelection(StructureTree tree, StructKid? kid, string type, IReadOnlyList<SelectedRun> runs)
    {
        if (runs.Count == 0) return AccessibilityText.ContentReason(TagContent.EmptySelection);
        foreach (var page in runs.GroupBy(r => r.Page).OrderBy(g => g.Key))
        {
            var result = tree.TagSelection(page.Key, page.Select(r => r.Range).ToList(), type.Trim(), ParentFor(kid));
            if (result.Reason is { } key) return AccessibilityText.ContentReason(key);
        }
        return null;
    }

    public static string? TagArea(StructureTree tree, StructKid? kid, string type, int page, PdfRect area) =>
        tree.TagArea(page, area, type.Trim(), ParentFor(kid)).Reason is { } key ? AccessibilityText.ContentReason(key) : null;

    /// <summary>Marks what the viewer has selected as an artifact: it is tagged as a span at the end of the tree and that span is marked at once.</summary>
    public static string? SelectionAsArtifact(StructureTree tree, IReadOnlyList<SelectedRun> runs)
    {
        if (runs.Count == 0) return AccessibilityText.ContentReason(TagContent.EmptySelection);
        foreach (var page in runs.GroupBy(r => r.Page).OrderBy(g => g.Key))
        {
            var result = tree.TagSelection(page.Key, page.Select(r => r.Range).ToList(), "Span", null);
            if (result.Reason is { } key) return AccessibilityText.ContentReason(key);
            if (tree.MarkAsArtifact(result.Element!) is { } why) return AccessibilityText.ContentReason(why);
        }
        return null;
    }
}
