using System.Text;

namespace LazyPDF.Core;

/// <summary>How a destination (ISO 32000-1 12.3.2.2, table 151) places the page in the window.</summary>
public enum DestinationFit { Xyz, Fit, FitH, FitV, FitR, FitB, FitBH, FitBV }

/// <summary>
/// A place in a document. <see cref="PageIndex"/> counts from 0 (-1 when the page is not there);
/// the numbers are in user space as the file has them, and only those the fit uses are set. A
/// destination given by name keeps it in <see cref="Name"/> (a byte string, one character per
/// byte) next to what the name resolved to.
/// </summary>
public sealed record PdfDestination(
    int PageIndex, DestinationFit Fit = DestinationFit.Fit, double? Left = null, double? Bottom = null,
    double? Right = null, double? Top = null, double? Zoom = null, string? Name = null);

/// <summary>Where a destination lands on its page, in display points from the top-left of the page as shown.</summary>
public readonly record struct DestinationPoint(int PageIndex, double X, double Y, double? Zoom);

/// <summary>The page positions and named destinations of a document, taken once so that reading a long list of destinations does not walk the tree and the name tree again for each.</summary>
internal sealed class DestContext(PdfDocument document)
{
    private Dictionary<int, int>? _index;
    private Dictionary<string, PdfObject>? _names;

    public int IndexOf(PdfObject? page)
    {
        if (_index is null)
        {
            _index = [];
            foreach (var p in document.Pages) _index.TryAdd(p.Reference.Number, p.Index);
        }
        return page is PdfReference r && _index.TryGetValue(r.Number, out int i) ? i : -1;
    }

    public PdfObject? LookUp(string name)
    {
        if (_names is null)
        {
            _names = [];
            foreach (var (key, value) in PdfNameTree.Read(document, document.Dict(document.Dict(document.Catalog, "Names"), "Dests"))) _names[key] = value;
            if (document.Dict(document.Catalog, "Dests") is { } dests)
            {
                foreach (var entry in dests.Entries.Take(100_000)) _names.TryAdd(entry.Key, entry.Value);
            }
        }
        return _names.GetValueOrDefault(name);
    }
}

/// <summary>Destinations: explicit arrays, named ones in /Dests and the /Names /Dests tree, and where they land.</summary>
public static class PdfDestinations
{
    private static readonly string[] FitNames = ["XYZ", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV"];

    /// <summary>
    /// A destination from an array, a dictionary with /D, or a name or string looked up in the
    /// document's named destinations. <paramref name="remote"/> is for the target of another file
    /// (the page is a number there, and a name is not looked up here). Null when it is none of these.
    /// </summary>
    public static PdfDestination? Parse(PdfDocument document, PdfObject? value, bool remote = false) =>
        Parse(document, value, new DestContext(document), remote);

    internal static PdfDestination? Parse(PdfDocument document, PdfObject? value, DestContext context, bool remote = false)
    {
        switch (document.Resolve(value))
        {
            case PdfArray array:
                return FromArray(document, array, context, remote);
            case PdfDictionary dictionary:
                return document.Resolve(dictionary["D"]) is PdfArray inner ? FromArray(document, inner, context, remote) : null;
            case PdfName name:
                return remote ? new PdfDestination(-1, Name: name.Value) : Named(document, name.Value, context);
            case PdfString text:
                string key = Encoding.Latin1.GetString(text.Bytes);
                return remote ? new PdfDestination(-1, Name: key) : Named(document, key, context);
            default:
                return null;
        }
    }

    // An unknown name stays a destination without a page, so the item that used it keeps it.
    private static PdfDestination Named(PdfDocument document, string name, DestContext context)
    {
        var found = document.Resolve(context.LookUp(name)) switch
        {
            PdfArray array => FromArray(document, array, context, false),
            PdfDictionary dictionary when document.Resolve(dictionary["D"]) is PdfArray inner => FromArray(document, inner, context, false),
            _ => null,
        };
        return (found ?? new PdfDestination(-1)) with { Name = name };
    }

    private static PdfDestination? FromArray(PdfDocument document, PdfArray array, DestContext context, bool remote)
    {
        if (array.Items.Count < 2 || document.Resolve(array.Items[1]) is not PdfName kind) return null;
        int fit = System.Array.IndexOf(FitNames, kind.Value);
        if (fit < 0) return null;
        int page;
        if (remote) page = document.Resolve(array.Items[0]) is PdfNumber { Integer: { } n and >= 0 and <= int.MaxValue } ? (int)n : -1;
        else page = context.IndexOf(array.Items[0]);

        double? N(int i) => i < array.Items.Count && document.Resolve(array.Items[i]) is PdfNumber { Value: var v } && double.IsFinite(v) ? v : null;
        return (DestinationFit)fit switch
        {
            DestinationFit.Xyz => new PdfDestination(page, DestinationFit.Xyz, Left: N(2), Top: N(3), Zoom: N(4)),
            DestinationFit.FitH or DestinationFit.FitBH => new PdfDestination(page, (DestinationFit)fit, Top: N(2)),
            DestinationFit.FitV or DestinationFit.FitBV => new PdfDestination(page, (DestinationFit)fit, Left: N(2)),
            DestinationFit.FitR => new PdfDestination(page, DestinationFit.FitR, N(2), N(3), N(4), N(5)),
            _ => new PdfDestination(page, (DestinationFit)fit),
        };
    }

    /// <summary>
    /// The value to store for a destination: its name when it has one (a string, or a name where
    /// the document keeps its destinations in a /Dests dictionary only), else the array. Null for a
    /// page that is not in the document.
    /// </summary>
    public static PdfObject? ToObject(PdfDocument document, PdfDestination destination, bool remote = false)
    {
        if (destination.Name is { } name)
        {
            bool oldStyle = TreeRoot(document) is null && document.Dict(document.Catalog, "Dests") is { } dests && dests.ContainsKey(name);
            return oldStyle ? new PdfName(name) : new PdfString(Encoding.Latin1.GetBytes(name), false);
        }
        PdfObject page;
        if (remote) page = new PdfNumber(Math.Max(0, destination.PageIndex));
        else if (destination.PageIndex >= 0 && destination.PageIndex < document.Pages.Count) page = document.Pages[destination.PageIndex].Reference;
        else return null;

        var items = new List<PdfObject> { page, new PdfName(FitNames[(int)destination.Fit]) };
        PdfObject N(double? v) => v is { } x && double.IsFinite(x) ? new PdfNumber(x) : PdfNull.Instance;
        switch (destination.Fit)
        {
            case DestinationFit.Xyz:
                items.AddRange([N(destination.Left), N(destination.Top), destination.Zoom is > 0 ? N(destination.Zoom) : PdfNull.Instance]);
                break;
            case DestinationFit.FitH or DestinationFit.FitBH:
                items.Add(N(destination.Top));
                break;
            case DestinationFit.FitV or DestinationFit.FitBV:
                items.Add(N(destination.Left));
                break;
            case DestinationFit.FitR:
                items.AddRange([N(destination.Left), N(destination.Bottom), N(destination.Right), N(destination.Top)]);
                break;
        }
        return new PdfArray(items);
    }

    /// <summary>
    /// Where the destination lands on its page as shown (crop box, rotation and user unit applied),
    /// kept inside the page. A missing coordinate is the page's own edge. Null when the page is not there.
    /// </summary>
    public static DestinationPoint? Locate(PdfDocument document, PdfDestination destination)
    {
        if (destination.PageIndex < 0 || destination.PageIndex >= document.Pages.Count) return null;
        var page = document.Pages[destination.PageIndex];
        var box = page.CropBox;
        var geometry = new PageGeometry(page);
        double x = box.Left, y = box.Top;
        switch (destination.Fit)
        {
            case DestinationFit.Xyz or DestinationFit.FitR:
                x = destination.Left ?? x;
                y = destination.Top ?? y;
                break;
            case DestinationFit.FitH or DestinationFit.FitBH:
                y = destination.Top ?? y;
                break;
            case DestinationFit.FitV or DestinationFit.FitBV:
                x = destination.Left ?? x;
                break;
        }
        var (dx, dy) = geometry.ToDisplay(x, y);
        double? zoom = destination.Fit == DestinationFit.Xyz && destination.Zoom is > 0 ? destination.Zoom : null;
        return new DestinationPoint(destination.PageIndex, Math.Clamp(dx, 0, geometry.Width), Math.Clamp(dy, 0, geometry.Height), zoom);
    }

    /// <summary>Every named destination: the /Dests dictionary (ISO 32000-1 12.3.2.3, files before 1.2), then the /Names /Dests tree. A name in both counts once, as the tree has it.</summary>
    public static IReadOnlyList<KeyValuePair<string, PdfDestination>> Named(PdfDocument document)
    {
        var context = new DestContext(document);
        var found = new Dictionary<string, PdfDestination>();
        var order = new List<string>();
        void Add(string name, PdfObject value)
        {
            if (document.Resolve(value) is not (PdfArray or PdfDictionary) || Parse(document, value, context) is not { } destination) return;
            if (!found.ContainsKey(name)) order.Add(name);
            found[name] = destination with { Name = name };
        }
        if (document.Dict(document.Catalog, "Dests") is { } dests)
        {
            foreach (var entry in dests.Entries.Take(100_000)) Add(entry.Key, entry.Value);
        }
        foreach (var (name, value) in PdfNameTree.Read(document, TreeRoot(document))) Add(name, value);
        return [.. order.Select(n => new KeyValuePair<string, PdfDestination>(n, found[n]))];
    }

    /// <summary>The destination a name stands for, or null when no such name is defined.</summary>
    public static PdfDestination? Find(PdfDocument document, string name) =>
        new DestContext(document) is var context && context.LookUp(name) is null ? null : Named(document, name, context);

    /// <summary>Gives <paramref name="name"/> a destination: in the /Dests dictionary when it is already there, else in the name tree (made if the file has none).</summary>
    public static void SetNamed(PdfDocument document, string name, PdfDestination destination)
    {
        if (ToObject(document, destination with { Name = null }) is not { } value)
        {
            throw new ArgumentException("The destination has no page in the document.", nameof(destination));
        }
        if (document.Dict(document.Catalog, "Dests") is { } old && old.ContainsKey(name))
        {
            old[name] = value;
            return;
        }
        var entries = PdfNameTree.Read(document, TreeRoot(document)).Where(e => e.Key != name).ToList();
        entries.Add(new(name, value));
        WriteTree(document, entries);
    }

    public static bool RemoveNamed(PdfDocument document, string name)
    {
        bool removed = document.Dict(document.Catalog, "Dests")?.Remove(name) == true;
        var entries = PdfNameTree.Read(document, TreeRoot(document));
        if (entries.Any(e => e.Key == name))
        {
            WriteTree(document, [.. entries.Where(e => e.Key != name)]);
            removed = true;
        }
        return removed;
    }

    private static PdfDictionary? TreeRoot(PdfDocument document) => document.Dict(document.Dict(document.Catalog, "Names"), "Dests");

    private static void WriteTree(PdfDocument document, List<KeyValuePair<string, PdfObject>> entries)
    {
        var names = PdfNames.Ensure(document);
        var existing = document.Dict(names, "Dests");
        var root = PdfNameTree.Write(document, existing, entries);
        if (existing is null) names["Dests"] = document.Add(root);
    }
}

internal static class PdfNames
{
    /// <summary>The catalog's /Names dictionary, made when the file has none.</summary>
    public static PdfDictionary Ensure(PdfDocument document)
    {
        if (document.Dict(document.Catalog, "Names") is { } names) return names;
        var created = new PdfDictionary();
        document.Catalog["Names"] = created;
        return created;
    }
}
