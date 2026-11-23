using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools.Pages;

/// <summary>The "Copy to tab" entries: the way to copy pages to another open file without dragging.</summary>
internal static class PageTransferMenu
{
    /// <summary>Replaces <paramref name="items"/> with one entry for each open file other than <paramref name="tab"/>. False when there is none.</summary>
    public static bool Fill(ItemCollection items, IToolHost host, DocumentTab tab, Func<List<int>> selected)
    {
        items.Clear();
        string pages = Loc.Plural(selected().Count, "{0} page", "{0} pages");
        foreach (var other in host.OpenDocuments)
        {
            if (ReferenceEquals(other, tab)) continue;
            // A single underscore in a header would be taken for an access key.
            var item = new MenuItem { Header = other.Title.Replace("_", "__") };
            AutomationProperties.SetName(item, Loc.T("Copy {0} to {1}", pages, other.Title));
            item.Click += async (_, _) =>
            {
                if (selected() is { Count: > 0 } picked) await PageTransfer.CopyAsync(new PagePayload(tab, [.. picked], tab.Revision), other, host);
            };
            items.Add(item);
        }
        return items.Count > 0;
    }
}
