namespace LazyPDF.Core;

/// <summary>
/// A script found in the form. <see cref="Event"/> is the /AA key of ISO 32000-1 12.6.3 and 12.7.5.3
/// (K keystroke, F format, V validate, C calculate, E X D U Fo Bl for the mouse and focus), "A" for a
/// widget's own action, "OpenAction", or "Names/" and the script's name for the document's scripts.
/// </summary>
/// <param name="Field">The full name of the field, null for a script of the document.</param>
/// <param name="BuiltIn">The text is only calls of the AF functions, which this layer implements.</param>
public sealed record FormScript(string? Field, string Event, string Source, bool BuiltIn)
{
    /// <summary>The script is applied by this layer: built-in, and an event that changes a value (K, F, V or C). Other JavaScript is listed and never run.</summary>
    public bool Ran => BuiltIn && Event is "K" or "F" or "V" or "C";
}

/// <summary>What <see cref="PdfForm.Recalculate"/> did: fields whose value changed and the calculations it could not run.</summary>
public sealed record FormCalculation(int Changed, IReadOnlyList<FormScript> NotRun);

/// <summary>Finding the scripts of a form (ISO 32000-1 12.6, 12.7.5.3).</summary>
public static class FormScripts
{
    private const int MaxScripts = 10_000;

    /// <summary>Every script of the document and of its fields and widgets, up to 10000.</summary>
    public static IReadOnlyList<FormScript> List(PdfForm form)
    {
        var document = form.Document;
        var list = new List<FormScript>();
        var all = PdfActions.ReadDocument(document);
        foreach (var script in all.Scripts) Add(list, null, "Names/" + script.Name, script.Script);
        if (all.OpenAction is { } open) AddAction(list, null, "OpenAction", open);
        foreach (var trigger in all.Triggers) AddAction(list, null, trigger.Event, trigger.Action);

        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (var field in form.Fields)
        {
            foreach (var d in field.Widgets.Select(w => w.Dictionary).Prepend(field.Dictionary))
            {
                if (list.Count >= MaxScripts) return list;
                if (!seen.Add(d)) continue;
                foreach (var trigger in PdfActions.Triggers(document, d)) AddAction(list, field.Name, trigger.Event, trigger.Action);
                if (d["A"] is not null && PdfActions.Read(document, d["A"]) is { } action) AddAction(list, field.Name, "A", action);
            }
        }
        return list;
    }

    /// <summary>The script of one event of a field: the field's own /AA first, then those of its widgets.</summary>
    internal static string? SourceOf(PdfForm form, FormField field, string evt)
    {
        foreach (var d in field.Widgets.Select(w => w.Dictionary).Prepend(field.Dictionary))
        {
            foreach (var trigger in PdfActions.Triggers(form.Document, d))
            {
                if (trigger.Event == evt && Scripts(trigger.Action).FirstOrDefault() is { } script) return script;
            }
        }
        return null;
    }

    /// <summary>The built-in calls of an event, null when it has no script or one that is not only built-in calls.</summary>
    internal static IReadOnlyList<FormCall>? CallsOf(PdfForm form, FormField field, string evt) =>
        SourceOf(form, field, evt) is { } source ? FormScriptParser.Parse(source) : null;

    private static void AddAction(List<FormScript> list, string? field, string evt, PdfAction action)
    {
        foreach (string source in Scripts(action)) Add(list, field, evt, source);
    }

    private static void Add(List<FormScript> list, string? field, string evt, string source)
    {
        if (list.Count < MaxScripts) list.Add(new FormScript(field, evt, source, FormScriptParser.Parse(source) is not null));
    }

    private static IEnumerable<string> Scripts(PdfAction action)
    {
        if (action is JavaScriptAction js) yield return js.Script;
        foreach (var next in action.Next)
        {
            foreach (string source in Scripts(next)) yield return source;
        }
    }
}
