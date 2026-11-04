namespace LazyPDF.Core;

public static partial class AccessibilityChecker
{
    private static readonly AccessibilityRule[] StructureRules =
    [
        AccessibilityRule.FigureAlt, AccessibilityRule.TableStructure, AccessibilityRule.TableHeaders, AccessibilityRule.ListStructure,
        AccessibilityRule.HeadingOrder, AccessibilityRule.RoleMap, AccessibilityRule.Links, AccessibilityRule.FormTagged,
    ];

    private static IEnumerable<AccessibilityItem> CheckStructure(PdfDocument document, StructureTree? tree)
    {
        var form = PdfForm.Read(document);
        yield return FormNames(form);
        if (tree is null)
        {
            foreach (var rule in StructureRules) yield return NoTags(rule);
            yield break;
        }

        var elements = tree.Elements.ToList();
        string Type(StructElement e) => tree.StandardType(e.Type);
        yield return FigureAlt(elements, Type);
        yield return Tables(document, elements, Type, headers: false);
        yield return Tables(document, elements, Type, headers: true);
        yield return Lists(elements, Type);
        yield return HeadingOrder(elements, Type);
        yield return RoleMap(tree, elements);
        yield return Links(document, tree, elements, Type);
        yield return FormTagged(form, elements);
    }

    private static int PageOf(StructElement element)
    {
        if (element.PageIndex >= 0) return element.PageIndex;
        foreach (var kid in element.Kids)
        {
            if (kid is StructContent { PageIndex: >= 0 } content) return content.PageIndex;
            if (kid is StructObject { PageIndex: >= 0 } target) return target.PageIndex;
        }
        return -1;
    }

    private static bool HasText(StructElement element) => !string.IsNullOrWhiteSpace(element.Alt) || !string.IsNullOrWhiteSpace(element.ActualText);

    private static IEnumerable<StructElement> Below(StructElement element) =>
        element.Children.SelectMany(c => new[] { c }.Concat(Below(c)));

    // 7.3 of ISO 14289-1: a figure has alternate text.
    private static AccessibilityItem FigureAlt(List<StructElement> elements, Func<StructElement, string> type)
    {
        var found = new Found();
        foreach (var e in elements.Where(e => type(e) == "Figure" && !HasText(e)))
        {
            found.Add(PageOf(e), e.Reference);
        }
        return found.Count == 0 ? Pass(AccessibilityRule.FigureAlt) : Fail(AccessibilityRule.FigureAlt, found);
    }

    // 7.5: a table has rows of cells, every row the same width, and header cells.
    private static AccessibilityItem Tables(PdfDocument document, List<StructElement> elements, Func<StructElement, string> type, bool headers)
    {
        var found = new Found();
        foreach (var table in elements.Where(e => type(e) == "Table"))
        {
            bool ok = headers ? Below(table).Any(e => type(e) == "TH") : IsRegular(document, table, type);
            if (!ok) found.Add(PageOf(table), table.Reference);
        }
        var rule = headers ? AccessibilityRule.TableHeaders : AccessibilityRule.TableStructure;
        return found.Count == 0 ? Pass(rule) : Fail(rule, found);
    }

    private static bool IsRegular(PdfDocument document, StructElement table, Func<StructElement, string> type)
    {
        var rows = new List<StructElement>();
        foreach (var child in table.Children)
        {
            string t = type(child);
            if (t == "TR") rows.Add(child);
            else if (t is "THead" or "TBody" or "TFoot")
            {
                foreach (var row in child.Children)
                {
                    if (type(row) != "TR") return false;
                    rows.Add(row);
                }
            }
            else if (t != "Caption") return false;
        }
        if (rows.Count == 0) return false;

        var widths = new HashSet<int>();
        foreach (var row in rows)
        {
            var cells = row.Children.ToList();
            if (cells.Count == 0 || cells.Any(c => type(c) is not ("TH" or "TD"))) return false;
            if (cells.Any(c => HasSpan(document, c))) return true;
            widths.Add(cells.Count);
        }
        return widths.Count == 1;
    }

    private static bool HasSpan(PdfDocument document, StructElement cell)
    {
        var attributes = document.Resolve(cell.Dictionary["A"]);
        var dictionaries = attributes switch
        {
            PdfDictionary d => [d],
            PdfArray a => a.Items.Select(document.Resolve).OfType<PdfDictionary>().ToList(),
            _ => new List<PdfDictionary>(),
        };
        return dictionaries.Any(d => d.ContainsKey("RowSpan") || d.ContainsKey("ColSpan"));
    }

    // 7.6: L holds LI, LI holds Lbl and LBody.
    private static AccessibilityItem Lists(List<StructElement> elements, Func<StructElement, string> type)
    {
        var found = new Found();
        foreach (var e in elements)
        {
            bool ok = type(e) switch
            {
                "L" => e.Children.All(c => type(c) is "LI" or "Caption"),
                "LI" => type(e.Parent ?? e) == "L" && e.Children.All(c => type(c) is "Lbl" or "LBody" or "L"),
                "Lbl" or "LBody" => e.Parent is { } parent && type(parent) == "LI",
                _ => true,
            };
            if (!ok) found.Add(PageOf(e), e.Reference);
        }
        return found.Count == 0 ? Pass(AccessibilityRule.ListStructure) : Fail(AccessibilityRule.ListStructure, found);
    }

    // 7.4: H1 comes first, a level is never skipped going down, and H is not mixed with H1 to H6.
    private static AccessibilityItem HeadingOrder(List<StructElement> elements, Func<StructElement, string> type)
    {
        var found = new Found();
        int previous = 0;
        bool plain = false, numbered = false;
        foreach (var e in elements)
        {
            string t = type(e);
            if (t == "H")
            {
                plain = true;
                if (numbered) found.Add(PageOf(e), e.Reference);
            }
            else if (t.Length > 1 && t[0] == 'H' && int.TryParse(t.AsSpan(1), out int level))
            {
                numbered = true;
                if (plain || level > previous + 1 || level > 6) found.Add(PageOf(e), e.Reference);
                previous = level;
            }
        }
        return found.Count == 0 ? Pass(AccessibilityRule.HeadingOrder) : Fail(AccessibilityRule.HeadingOrder, found);
    }

    // 7.1: a type that is not standard is mapped to one that is.
    private static AccessibilityItem RoleMap(StructureTree tree, List<StructElement> elements)
    {
        var found = new Found();
        var seen = new HashSet<string>();
        foreach (var e in elements)
        {
            if (!StructureTree.IsStandard(tree.StandardType(e.Type)) && seen.Add(e.Type)) found.Add(PageOf(e), e.Reference);
        }
        return found.Count == 0 ? Pass(AccessibilityRule.RoleMap) : Fail(AccessibilityRule.RoleMap, found);
    }

    // 7.18.5: a link annotation sits in a Link element and has text for a reader.
    private static AccessibilityItem Links(PdfDocument document, StructureTree tree, List<StructElement> elements, Func<StructElement, string> type)
    {
        var owners = new Dictionary<int, StructElement>();
        foreach (var e in elements)
        {
            foreach (var target in e.Kids.OfType<StructObject>()) owners.TryAdd(target.Target.Number, e);
        }

        var found = new Found();
        int budget = 50_000;
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (--budget < 0) break;
                if (item is not PdfReference reference || document.Resolve(item) is not PdfDictionary annotation || document.Name(annotation, "Subtype") != "Link") continue;
                bool described = !string.IsNullOrWhiteSpace(PdfText.Read(document, annotation, "Contents"));
                if (!owners.TryGetValue(reference.Number, out var owner)) found.Add(page.Index, reference);
                else if (!described && !HasText(owner) && !HasContent(owner)) found.Add(page.Index, reference);
            }
        }
        foreach (var e in elements.Where(e => type(e) == "Link" && e.Kids.Count == 0 && !HasText(e))) found.Add(PageOf(e), e.Reference);
        return found.Count == 0 ? Pass(AccessibilityRule.Links) : Fail(AccessibilityRule.Links, found);
    }

    private static bool HasContent(StructElement element) =>
        element.Kids.OfType<StructContent>().Any() || Below(element).Any(e => e.Kids.OfType<StructContent>().Any());

    // 7.18.1 and 7.18.4: a field has a name and a description.
    private static AccessibilityItem FormNames(PdfForm form)
    {
        var found = new Found();
        foreach (var field in form.Fields)
        {
            if (string.IsNullOrWhiteSpace(field.Name) || string.IsNullOrWhiteSpace(field.Tooltip))
            {
                found.Add(field.Widgets.Count > 0 ? field.Widgets[0].PageIndex : -1, field.Reference);
            }
        }
        return found.Count == 0 ? Pass(AccessibilityRule.FormNames) : Fail(AccessibilityRule.FormNames, found);
    }

    private static AccessibilityItem FormTagged(PdfForm form, List<StructElement> elements)
    {
        var tagged = new HashSet<int>(elements.SelectMany(e => e.Kids.OfType<StructObject>()).Select(o => o.Target.Number));
        var found = new Found();
        foreach (var field in form.Fields)
        {
            foreach (var widget in field.Widgets)
            {
                if (widget.Reference is { } reference && !tagged.Contains(reference.Number)) found.Add(widget.PageIndex, reference);
            }
        }
        return found.Count == 0 ? Pass(AccessibilityRule.FormTagged) : Fail(AccessibilityRule.FormTagged, found);
    }
}
