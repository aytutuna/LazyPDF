using System.Runtime.CompilerServices;

namespace LazyPDF.Core;

/// <summary>
/// The objects of the file as the redaction sees them: what an object leads to, and the last sweep that empties what a
/// redacted page reached and nothing painted reaches. Emptying is done where the object is, so whoever still names it
/// (structure elements, private data, thumbnails, page-level keys) holds an empty one.
/// </summary>
internal static class RedactionObjects
{
    /// <summary>
    /// The keys by which a stream is part of what is painted, the keys whose dictionaries hold such streams under
    /// names of their own, and the keys that hold pictures and forms. Every other value is followed, but a stream only
    /// through one of these: an object that something merely names does not stay for it.
    /// </summary>
    public sealed record Reading(HashSet<string> Streams, HashSet<string> Wide, HashSet<string> Objects);

    // The masks of a picture are read through the picture, the one place where /SMask and /Mask mean a stream.
    private static readonly string[] PaintKeys =
    [
        "ColorSpace", "CS", "Alternate", "Function", "Functions", "Process", "Colorants", "Shading", "TR", "TR2", "BG", "BG2", "UCR", "UCR2",
        "HT", "TransferFunction", "FontFile", "FontFile2", "FontFile3", "ToUnicode", "UseCMap", "CIDToGIDMap", "CIDSet", "Encoding", "CharProcs",
        "DestOutputProfile", "JBIG2Globals",
    ];

    private static readonly string[] Masks = ["SMask", "Mask"];

    /// <summary>What a page paints through: its pictures, fonts, colour spaces and the functions of its states.</summary>
    public static readonly Reading Painting = new([.. PaintKeys], ["CharProcs", "Colorants"], []);

    /// <summary>The same, and an annotation's own appearances, which the walk enters as forms.</summary>
    public static readonly Reading Annotating = new([.. PaintKeys, "V", "DV", "RC"], ["CharProcs", "Colorants"], []);

    // Everything a page lists, for a page that cannot be followed to see what it paints.
    private static readonly string[] ListKeys = ["Contents", "XObject", "Pattern", "Shading", "AP", "N", "D", "R"];

    /// <summary>All a page could paint: every entry of its resource lists and every appearance.</summary>
    public static readonly Reading Listing = new([.. PaintKeys, .. ListKeys], ["CharProcs", "Colorants", "XObject", "Pattern", "Shading", "N", "D", "R"], [.. ListKeys]);

    private static readonly Reading Layers = new([], [], []);

    // Found once, before any page is rewritten, so that the content streams are the ones the pages named.
    private sealed record Skeleton(HashSet<PdfObject> Tree, HashSet<PdfObject> Contents);

    private sealed record Item(PdfObject? Value, bool Stream, bool Wide, bool Listed, bool Objects);

    private static readonly ConditionalWeakTable<PdfDocument, Skeleton> Skeletons = new();

    /// <summary>
    /// Adds the numbers of every object <paramref name="root"/> leads to. Pages, page tree nodes and the catalog are not
    /// part of what a page holds, whatever names them (destinations, annotations, tags), unless a resource list is one.
    /// <paramref name="apart"/> are keys of the root itself that are left out.
    /// </summary>
    public static void Collect(PdfDocument document, PdfObject? root, HashSet<int> into, params string[] apart) =>
        Follow(document, root, into, null, true, apart);

    /// <summary>
    /// As <see cref="Collect"/>, but a stream is followed only by the keys of <paramref name="reading"/>, and the root is
    /// not one: it is a dictionary, an array or a name that something paints through.
    /// </summary>
    public static void Painted(PdfDocument document, PdfObject? root, HashSet<int> into, Reading reading, params string[] apart) =>
        Follow(document, root, into, reading, false, apart);

    /// <summary>As <see cref="Painted"/>, for a root that is painted itself: a picture, a form, a pattern cell or content.</summary>
    public static void PaintedStream(PdfDocument document, PdfObject? root, HashSet<int> into, Reading reading, params string[] apart) =>
        Follow(document, root, into, reading, true, apart);

    /// <summary>A picture, form, pattern cell, packet of metadata, attachment or content of a page: nothing a font or a colour is made of.</summary>
    public static bool Barred(PdfDocument document, PdfStream stream) =>
        document.Name(stream.Dictionary, "Subtype") is "Image" or "Form" or "XML" || document.Name(stream.Dictionary, "Type") is "XObject" or "Metadata" or "EmbeddedFile"
        || stream.Dictionary.ContainsKey("PatternType") || Skeletons.GetValue(document, Find).Contents.Contains(stream);

    public static bool IsImage(PdfDocument document, PdfStream stream) => document.Name(stream.Dictionary, "Subtype") == "Image";

    /// <summary>Whether the object is the catalog, a page tree node or a page.</summary>
    public static bool InTree(PdfDocument document, PdfObject? value) =>
        document.Resolve(value) is { } resolved && Skeletons.GetValue(document, Find).Tree.Contains(resolved);

    private static void Follow(PdfDocument document, PdfObject? root, HashSet<int> into, Reading? reading, bool stream, string[] apart)
    {
        var skeleton = Skeletons.GetValue(document, Find);
        var pending = new Stack<Item>();
        var entered = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        void Open(Item item, string[] skipped)
        {
            var value = item.Value;
            while (value is PdfReference reference)
            {
                if (document.Get(reference.Number) is not { } target) return;
                if (skeleton.Tree.Contains(target))
                {
                    // A tree node named as a resource list is a list, not structure: what it holds is followed and the node itself is not swept.
                    if (!item.Listed || !entered.Add(target)) return;
                    (value, item) = (target, item with { Listed = false });
                    break;
                }
                if (target is PdfStream held && (!item.Stream || reading is not null && !item.Objects && Barred(document, held)) || !into.Add(reference.Number)) return;
                value = target;
            }
            switch (value)
            {
                case PdfStream held:
                    Open(item with { Value = held.Dictionary, Stream = false, Wide = false }, skipped);
                    if (reading is null || !IsImage(document, held)) break;
                    foreach (string key in Masks)
                    {
                        if (held.Dictionary[key] is { } mask && document.Resolve(mask) is PdfStream picture && IsImage(document, picture)) pending.Push(new Item(mask, true, false, false, true));
                    }
                    break;
                case PdfDictionary dictionary:
                    foreach (var (key, member) in dictionary.Entries)
                    {
                        if (skipped.Contains(key)) continue;
                        bool grants = item.Wide || reading is null || reading.Streams.Contains(key);
                        bool wide = !item.Wide && reading is not null && reading.Wide.Contains(key);
                        bool objects = item.Wide && item.Objects || reading is not null && reading.Objects.Contains(key);
                        pending.Push(new Item(member, grants, wide, item.Listed || key == "Resources", objects));
                    }
                    break;
                case PdfArray array:
                    foreach (var member in array.Items) pending.Push(item with { Value = member, Wide = false });
                    break;
            }
        }
        Open(new Item(root, stream, false, false, stream), apart);
        while (pending.Count > 0) Open(pending.Pop(), []);
    }

    // The catalog, the page tree and every page, by their place in the tree and not by a /Type that anything can claim.
    private static Skeleton Find(PdfDocument d)
    {
        const int MaxDepth = 256;
        var nodes = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance) { d.Catalog };
        var open = new Stack<(PdfObject? Node, int Depth)>();
        open.Push((d.Catalog["Pages"], 0));
        while (open.Count > 0)
        {
            var (node, depth) = open.Pop();
            if (d.Resolve(node) is not PdfDictionary dictionary || depth > MaxDepth || !nodes.Add(dictionary)) continue;
            if (d.Resolve(dictionary["Kids"]) is PdfArray kids)
            {
                foreach (var kid in kids.Items) open.Push((kid, depth + 1));
            }
        }
        var contents = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        foreach (var page in d.Pages)
        {
            nodes.Add(page.Dictionary);
            contents.UnionWith(RedactionResources.Contents(d, page));
        }
        return new Skeleton(nodes, contents);
    }

    /// <summary>
    /// Empties every object in <paramref name="reached"/> that is not in <paramref name="painted"/>. The layers and the
    /// output intents stay: pages that were not redacted depend on them.
    /// </summary>
    public static void Sweep(PdfDocument document, HashSet<int> reached, HashSet<int> painted)
    {
        Painted(document, document.Catalog["OCProperties"], painted, Layers);
        Painted(document, document.Catalog["OutputIntents"], painted, Painting);
        foreach (int number in reached.Where(n => !painted.Contains(n)))
        {
            switch (document.Get(number))
            {
                case PdfStream stream:
                    stream.Data = [];
                    Clear(stream.Dictionary);
                    break;
                case PdfDictionary dictionary:
                    Clear(dictionary);
                    break;
                case PdfArray array:
                    array.Items.Clear();
                    break;
                case null or PdfNull:
                    break;
                default:
                    document.Set(number, PdfNull.Instance);
                    break;
            }
        }
    }

    private static void Clear(PdfDictionary dictionary)
    {
        foreach (var (key, _) in dictionary.Entries.ToList()) dictionary.Remove(key);
    }
}
