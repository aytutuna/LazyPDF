namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    /// <summary>The page's /Tabs setting; <see cref="TabOrder.Annotations"/> when it has none.</summary>
    public TabOrder GetTabOrder(int pageIndex) => _document.Name(PageAt(pageIndex).Dictionary, "Tabs") switch
    {
        "R" => TabOrder.Row,
        "C" => TabOrder.Column,
        "S" => TabOrder.Structure,
        _ => TabOrder.Annotations,
    };

    public void SetTabOrder(int pageIndex, TabOrder order)
    {
        var page = PageAt(pageIndex);
        string? name = order switch { TabOrder.Row => "R", TabOrder.Column => "C", TabOrder.Structure => "S", _ => null };
        if (name is null) page.Dictionary.Remove("Tabs");
        else page.Dictionary["Tabs"] = new PdfName(name);
    }

    /// <summary>
    /// The page's widgets in the order Tab visits them. Row order reads top to bottom and left to right,
    /// column order left to right and top to bottom; structure order is not followed and reads as the
    /// order of /Annots, which is also what no setting means.
    /// </summary>
    public IReadOnlyList<FormWidget> TabSequence(int pageIndex)
    {
        var onPage = _fields.SelectMany(f => f.Widgets).Where(w => w.PageIndex == pageIndex).ToList();
        var annots = _document.Array(PageAt(pageIndex).Dictionary, "Annots");
        var inFile = onPage.OrderBy(w => annots?.Items.FindIndex(i => ReferenceEquals(_document.Resolve(i), w.Dictionary)) ?? 0).ToList();
        return GetTabOrder(pageIndex) switch
        {
            TabOrder.Row => Lines(inFile, w => w.Rect.Top, w => w.Rect.Height, w => w.Rect.Left, descending: true),
            TabOrder.Column => Lines(inFile, w => w.Rect.Left, w => w.Rect.Width, w => w.Rect.Top, descending: false, secondDescending: true),
            _ => inFile,
        };
    }

    /// <summary>
    /// Sets the order Tab visits the listed widgets of a page by moving them within /Annots, keeping the
    /// slots they hold, and clears the page's /Tabs so that this order is the one used.
    /// </summary>
    public void ReorderWidgets(int pageIndex, IReadOnlyList<FormWidget> order)
    {
        var page = PageAt(pageIndex);
        page.Dictionary.Remove("Tabs");
        if (_document.Array(page.Dictionary, "Annots") is not { } annots) return;
        var slots = new List<int>();
        var members = new HashSet<PdfDictionary>(order.Select(w => w.Dictionary), ReferenceEqualityComparer.Instance);
        for (int i = 0; i < annots.Items.Count; i++)
        {
            if (_document.Resolve(annots.Items[i]) is PdfDictionary d && members.Contains(d)) slots.Add(i);
        }
        var items = order.Select(w => annots.Items.FirstOrDefault(i => ReferenceEquals(_document.Resolve(i), w.Dictionary))).OfType<PdfObject>().ToList();
        for (int i = 0; i < slots.Count && i < items.Count; i++) annots.Items[slots[i]] = items[i];
    }

    // Widgets grouped into lines by their position across (a line holds those within half the first one's size of it), lines in order, each read along.
    private static List<FormWidget> Lines(List<FormWidget> widgets, Func<FormWidget, double> across, Func<FormWidget, double> size,
        Func<FormWidget, double> along, bool descending, bool secondDescending = false)
    {
        var sorted = descending ? widgets.OrderByDescending(across).ToList() : widgets.OrderBy(across).ToList();
        var lines = new List<List<FormWidget>>();
        foreach (var w in sorted)
        {
            if (lines.Count > 0 && Math.Abs(across(lines[^1][0]) - across(w)) <= size(lines[^1][0]) / 2) lines[^1].Add(w);
            else lines.Add([w]);
        }
        return [.. lines.SelectMany(l => secondDescending ? l.OrderByDescending(along) : l.OrderBy(along))];
    }
}
