using System.Text;

namespace LazyPDF.Core;

/// <summary>An action (ISO 32000-1 12.6). <see cref="Next"/> are the actions that follow it, in order.</summary>
public abstract record PdfAction
{
    public IReadOnlyList<PdfAction> Next { get; init; } = [];
}

public sealed record GoToAction(PdfDestination Destination) : PdfAction;

/// <summary>Go to a place in another file. <see cref="Destination"/> holds a page number there, or a name that is not resolved here.</summary>
public sealed record GoToRemoteAction(string File, PdfDestination? Destination, bool? NewWindow) : PdfAction;

public sealed record LaunchAction(string? File, bool? NewWindow) : PdfAction;

public sealed record UriAction(string Uri) : PdfAction;

/// <summary>NextPage, PrevPage, FirstPage, LastPage or a menu command the viewer may know.</summary>
public sealed record NamedAction(string Name) : PdfAction;

public sealed record JavaScriptAction(string Script) : PdfAction;

/// <summary><see cref="Flags"/> are the /Flags bits of table 237; <see cref="Fields"/> the names it lists (none: every field).</summary>
public sealed record SubmitFormAction(string Url, int Flags, IReadOnlyList<string> Fields) : PdfAction;

public sealed record ResetFormAction(int Flags, IReadOnlyList<string> Fields) : PdfAction;

/// <summary>An action this layer does not unpack: Hide, ImportData, SetOCGState, Sound, Movie, Rendition, Thread, Trans, GoToE, GoTo3DView and the like.</summary>
public sealed record OtherAction(string Type) : PdfAction;

/// <summary>An additional action of an object (/AA): the event key ("WC", "O", "E", "Fo"...) and what it runs.</summary>
public sealed record PdfTrigger(string Event, PdfAction Action);

public sealed record NamedScript(string Name, string Script);

/// <summary>What a document runs by itself: its open action, its events and the scripts of its name tree.</summary>
public sealed record DocumentActions(PdfAction? OpenAction, IReadOnlyList<PdfTrigger> Triggers, IReadOnlyList<NamedScript> Scripts);

public static class PdfActions
{
    private const int MaxActions = 64;
    private const int MaxDepth = 8;
    private const int MaxAnnotations = 50_000;

    /// <summary>
    /// The action in <paramref name="value"/> (a dictionary), with the actions that follow it. At
    /// most 64 are read and a chain that loops stops at the repeat. Null when it has no known /S.
    /// </summary>
    public static PdfAction? Read(PdfDocument document, PdfObject? value) =>
        Read(document, value, new DestContext(document));

    internal static PdfAction? Read(PdfDocument document, PdfObject? value, DestContext context)
    {
        int budget = MaxActions;
        return Read(document, value, context, [], 0, ref budget);
    }

    private static PdfAction? Read(PdfDocument document, PdfObject? value, DestContext context, HashSet<int> seen, int depth, ref int budget)
    {
        if (depth > MaxDepth || budget <= 0) return null;
        if (value is PdfReference reference && !seen.Add(reference.Number)) return null;
        if (document.Resolve(value) is not PdfDictionary dictionary || document.Name(dictionary, "S") is not { } type) return null;
        budget--;

        var next = new List<PdfAction>();
        var follow = document.Resolve(dictionary["Next"]);
        foreach (var item in follow is PdfArray array ? array.Items : follow is null ? [] : [dictionary["Next"]!])
        {
            if (Read(document, item, context, seen, depth + 1, ref budget) is { } action) next.Add(action);
        }

        PdfAction? result = type switch
        {
            "GoTo" => PdfDestinations.Parse(document, dictionary["D"], context) is { } d ? new GoToAction(d) : null,
            "GoToR" => new GoToRemoteAction(FileName(document, dictionary["F"]) ?? "", PdfDestinations.Parse(document, dictionary["D"], context, remote: true), document.Bool(dictionary, "NewWindow")),
            "Launch" => new LaunchAction(FileName(document, dictionary["F"]), document.Bool(dictionary, "NewWindow")),
            "URI" => document.Resolve(dictionary["URI"]) is PdfString uri ? new UriAction(UriText(uri.Bytes)) : null,
            "Named" => new NamedAction(document.Name(dictionary, "N") ?? ""),
            "JavaScript" => new JavaScriptAction(PdfText.Read(document, dictionary["JS"]) ?? ""),
            "SubmitForm" => new SubmitFormAction(FileName(document, dictionary["F"]) ?? "", (int)(document.Integer(dictionary, "Flags") ?? 0), Fields(document, dictionary)),
            "ResetForm" => new ResetFormAction((int)(document.Integer(dictionary, "Flags") ?? 0), Fields(document, dictionary)),
            _ => new OtherAction(type),
        };
        return result is null ? null : result with { Next = next };
    }

    /// <summary>The action to store for <paramref name="action"/>, with its chain. An <see cref="OtherAction"/> cannot be written.</summary>
    public static PdfDictionary ToObject(PdfDocument document, PdfAction action)
    {
        var d = new PdfDictionary { ["Type"] = new PdfName("Action") };
        switch (action)
        {
            case GoToAction a:
                d["S"] = new PdfName("GoTo");
                d["D"] = PdfDestinations.ToObject(document, a.Destination) ?? throw new ArgumentException("The destination has no page in the document.", nameof(action));
                break;
            case GoToRemoteAction a:
                d["S"] = new PdfName("GoToR");
                d["F"] = PdfText.ToObject(a.File);
                if (a.Destination is not null) d["D"] = PdfDestinations.ToObject(document, a.Destination, remote: true)!;
                if (a.NewWindow is { } w) d["NewWindow"] = new PdfBoolean(w);
                break;
            case LaunchAction a:
                d["S"] = new PdfName("Launch");
                if (a.File is not null) d["F"] = PdfText.ToObject(a.File);
                if (a.NewWindow is { } w2) d["NewWindow"] = new PdfBoolean(w2);
                break;
            case UriAction a:
                d["S"] = new PdfName("URI");
                d["URI"] = new PdfString(Encoding.UTF8.GetBytes(a.Uri), false);
                break;
            case NamedAction a:
                d["S"] = new PdfName("Named");
                d["N"] = new PdfName(a.Name);
                break;
            case JavaScriptAction a:
                d["S"] = new PdfName("JavaScript");
                d["JS"] = PdfText.ToObject(a.Script);
                break;
            case SubmitFormAction a:
                d["S"] = new PdfName("SubmitForm");
                d["F"] = new PdfDictionary { ["FS"] = new PdfName("URL"), ["F"] = PdfText.ToFileName(a.Url) };
                SetFields(d, a.Flags, a.Fields);
                break;
            case ResetFormAction a:
                d["S"] = new PdfName("ResetForm");
                SetFields(d, a.Flags, a.Fields);
                break;
            default:
                throw new ArgumentException("This kind of action cannot be written.", nameof(action));
        }
        if (action.Next.Count == 1) d["Next"] = ToObject(document, action.Next[0]);
        else if (action.Next.Count > 1) d["Next"] = new PdfArray([.. action.Next.Select(n => (PdfObject)ToObject(document, n))]);
        return d;
    }

    /// <summary>The additional actions (/AA) of a catalog, page, annotation or field.</summary>
    public static IReadOnlyList<PdfTrigger> Triggers(PdfDocument document, PdfDictionary? owner)
    {
        var triggers = new List<PdfTrigger>();
        if (document.Dict(owner, "AA") is not { } events) return triggers;
        var context = new DestContext(document);
        foreach (var entry in events.Entries.Take(MaxActions))
        {
            if (Read(document, entry.Value, context) is { } action) triggers.Add(new PdfTrigger(entry.Key, action));
        }
        return triggers;
    }

    /// <summary>The open action, the document events (/AA of the catalog) and the /Names /JavaScript scripts.</summary>
    public static DocumentActions ReadDocument(PdfDocument document)
    {
        var context = new DestContext(document);
        PdfAction? open = null;
        if (document.Resolve(document.Catalog["OpenAction"]) is PdfArray array)
        {
            if (PdfDestinations.Parse(document, array, context) is { } destination) open = new GoToAction(destination);
        }
        else open = Read(document, document.Catalog["OpenAction"], context);

        var scripts = new List<NamedScript>();
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "JavaScript");
        foreach (var (name, value) in PdfNameTree.Read(document, tree))
        {
            if (Read(document, value, context) is JavaScriptAction script) scripts.Add(new NamedScript(PdfNameTree.TextOf(name), script.Script));
        }
        return new DocumentActions(open, Triggers(document, document.Catalog), scripts);
    }

    /// <summary>
    /// Whether anything in the file can run a script: the open action, the document events, the
    /// script tree, and the actions and events of pages, links and form widgets (up to 50000
    /// annotations).
    /// </summary>
    public static bool HasJavaScript(PdfDocument document)
    {
        var context = new DestContext(document);
        bool Runs(PdfDictionary? owner)
        {
            if (owner is null) return false;
            if (Read(document, owner["A"], context) is { } a && ContainsScript(a)) return true;
            return Triggers(document, owner).Any(t => ContainsScript(t.Action));
        }

        var all = ReadDocument(document);
        if (all.Scripts.Count > 0 || (all.OpenAction is { } open && ContainsScript(open)) || all.Triggers.Any(t => ContainsScript(t.Action))) return true;
        int annotations = 0;
        foreach (var page in document.Pages)
        {
            if (Runs(page.Dictionary)) return true;
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (++annotations > MaxAnnotations) return false;
                if (Runs(document.Resolve(item) as PdfDictionary)) return true;
            }
        }
        return false;
    }

    private static bool ContainsScript(PdfAction action) => action is JavaScriptAction || action.Next.Any(ContainsScript);

    /// <summary>The file name of a file specification: a string, or the /UF or /F of a dictionary.</summary>
    internal static string? FileName(PdfDocument document, PdfObject? value) => document.Resolve(value) switch
    {
        PdfString s => PdfText.Decode(s.Bytes),
        PdfDictionary d => PdfText.Read(document, d, "UF") ?? PdfText.Read(document, d, "F"),
        _ => null,
    };

    private static string UriText(byte[] bytes)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (ArgumentException)
        {
            return Encoding.Latin1.GetString(bytes);
        }
    }

    private static List<string> Fields(PdfDocument document, PdfDictionary action)
    {
        var names = new List<string>();
        if (document.Array(action, "Fields") is not { } fields) return names;
        foreach (var item in fields.Items.Take(10_000))
        {
            switch (document.Resolve(item))
            {
                case PdfString s: names.Add(PdfText.Decode(s.Bytes)); break;
                case PdfDictionary field when PdfText.Read(document, field, "T") is { } name: names.Add(name); break;
            }
        }
        return names;
    }

    private static void SetFields(PdfDictionary action, int flags, IReadOnlyList<string> fields)
    {
        if (flags != 0) action["Flags"] = new PdfNumber(flags);
        if (fields.Count > 0) action["Fields"] = new PdfArray([.. fields.Select(f => (PdfObject)PdfText.ToObject(f))]);
    }
}
