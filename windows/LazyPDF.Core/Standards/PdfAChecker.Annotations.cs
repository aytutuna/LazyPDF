namespace LazyPDF.Core;

// Annotations, actions and interactive forms (ISO 19005-1 6.5, 6.6, 6.9; 19005-2 6.3, 6.4, 6.5).
internal sealed partial class PdfAChecker
{
    private const int MaxAnnotations = 50_000;

    // What walking an annotation, and resolving one of its appearance states, cost in the work budget; /Annots and /N are often shared by many pages.
    private const int AnnotationWork = 256;
    private const int StateWork = 64;
    private readonly HashSet<PdfArray> _nextLists = new(ReferenceEqualityComparer.Instance);

    private static readonly string[] Part1Annotations =
        ["Text", "Link", "FreeText", "Line", "Square", "Circle", "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Ink", "Popup", "Widget", "PrinterMark", "TrapNet"];

    private static readonly string[] LaterAnnotations = [.. Part1Annotations, "Polygon", "PolyLine", "Caret", "FileAttachment", "Redact", "Watermark"];

    internal static readonly string[] ForbiddenActions = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "JavaScript", "Hide", "SetOCGState", "Rendition", "Trans", "GoTo3DView", "SetState", "NOP"];

    internal static readonly string[] NamedActions = ["NextPage", "PrevPage", "FirstPage", "LastPage"];

    /// <summary>The annotation subtypes a part allows, before the rule about attachments.</summary>
    internal static string[] AllowedAnnotations(int part) => part == 1 ? Part1Annotations : LaterAnnotations;

    private readonly HashSet<PdfStream> _appearancesRun = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfDictionary> _actionsSeen = new(ReferenceEqualityComparer.Instance);

    private void CheckAnnotations(PdfPage page, int pageNumber, ContentInterpreter interpreter)
    {
        if (_doc.Array(page.Dictionary, "Annots") is not { } annotations) return;
        string flags = C("6.5.3", "6.3.2"), appearance = C("6.5.3", "6.3.3");
        for (int i = 0; i < annotations.Items.Count && i < MaxAnnotations && !OverBudget; i++)
        {
            _work += AnnotationWork;
            if (_doc.Resolve(annotations.Items[i]) is not PdfDictionary annotation) continue;
            string where = PdfAText.AnnotationName(pageNumber, i + 1);
            string? subtype = _doc.Name(annotation, "Subtype");
            if (subtype is null || !AllowedAnnotations(Part).Contains(subtype))
            {
                Add(C("6.5.2", "6.3.1"), where, PdfAText.AnnotationType(subtype));
                continue;
            }
            if (subtype == "FileAttachment" && Part == 4) Add("6.3.1", where, PdfAText.EmbeddedFile);
            if (IsPart1 && (_doc.Number(annotation, "CA") is < 1)) Add(ClauseTransparency, where, PdfAText.Opacity);
            if (subtype == "Widget" && annotation.ContainsKey("A")) Add(C("6.6.1", "6.4.1"), where, PdfAText.WidgetAction);
            CheckAction(annotation["A"], where);
            CheckTriggers(annotation, where, subtype == "Widget");
            if (IsPart1 && _intentComponents != 3 && (HasColor(annotation, "C") || HasColor(annotation, "IC"))) Add("6.5.3", where, PdfAText.AnnotationColor);

            if (subtype == "Popup") continue;
            long f = _doc.Integer(annotation, "F") ?? 0;
            if ((f & 4) == 0) Add(flags, where, PdfAText.NoPrintFlag);
            if ((f & (1 | 2 | 32)) != 0) Add(flags, where, PdfAText.HiddenAnnotation);
            CheckAppearance(annotation, subtype, where, appearance, interpreter);
        }
    }

    private void CheckAppearance(PdfDictionary annotation, string subtype, string where, string clause, ContentInterpreter interpreter)
    {
        var ap = _doc.Dict(annotation, "AP");
        bool zeroArea = !IsPart1 && _doc.Rect(annotation, "Rect") is null;
        if (ap is null || ap["N"] is null)
        {
            if (subtype != "Link" && !zeroArea) Add(clause, where, PdfAText.NoAppearance);
            return;
        }
        if (ap.Entries.Any(e => e.Key != "N")) Add(clause, where, PdfAText.AppearanceKeys);
        bool button = subtype == "Widget" && FieldType(annotation) == "Btn";
        var normal = _doc.Resolve(ap["N"]);
        if (button != (normal is PdfDictionary)) Add(clause, where, button ? PdfAText.ButtonAppearance : PdfAText.AppearanceNotStream);
        var streams = normal switch
        {
            PdfStream s => [s],
            PdfDictionary states => states.Entries.Take(256).Select(e => _doc.Resolve(e.Value)).OfType<PdfStream>().ToList(),
            _ => new List<PdfStream>(),
        };
        _work += (long)streams.Count * StateWork;
        foreach (var stream in streams)
        {
            CheckFormStream(stream, where);
            if (!_appearancesRun.Add(stream)) continue;
            try
            {
                interpreter.Run(stream, new Visitor(this, where, null));
                if (interpreter.IsTruncated) Add("6.1.7", where, PdfAText.TooMuchContent);
            }
            catch (PdfReadException)
            {
                Unreadable(where);
            }
        }
    }

    private bool HasColor(PdfDictionary annotation, string key) => _doc.Array(annotation, key) is { Items.Count: > 0 };

    /// <summary>/FT of the field a widget belongs to, found up the /Parent chain.</summary>
    private string? FieldType(PdfDictionary field)
    {
        for (int hops = 0; field is not null && hops < 32; hops++)
        {
            if (_doc.Name(field, "FT") is { } type) return type;
            field = _doc.Dict(field, "Parent")!;
        }
        return null;
    }

    // Widgets and fields may not have an /AA through part 3 (6.6.2, 6.4.1); part 4 drops that ban and limits the keys of every other owner (6.6.3).
    private void CheckTriggers(PdfDictionary owner, string where, bool field)
    {
        if (_doc.Dict(owner, "AA") is not { } triggers) return;
        if (field && Part != 4) Add(C("6.6.2", "6.4.1"), where, PdfAText.FieldTriggers);
        foreach (var (key, action) in triggers.Entries.Take(64))
        {
            if (Part == 4 && !field && key is not ("E" or "X" or "D" or "U" or "Fo" or "Bl")) Add("6.6.3", where, PdfAText.TriggerKey(key));
            CheckAction(action, where);
        }
    }

    // An action is judged once wherever it is reached from, and a /Next chain is followed to its end: a loop or a shared tail, array or action, costs nothing more.
    private void CheckAction(PdfObject? value, string where)
    {
        var pending = new Stack<PdfObject?>();
        pending.Push(value);
        string clause = C("6.6.1", "6.5.1");
        while (pending.Count > 0)
        {
            if (_doc.Resolve(pending.Pop()) is not PdfDictionary action || !_actionsSeen.Add(action)) continue;
            string? type = _doc.Name(action, "S");
            if (type is not null && ForbiddenActions.Contains(type)) Add(clause, where, type == "JavaScript" ? PdfAText.JavaScript : PdfAText.ForbiddenAction(type));
            else if (type == "Named" && !NamedActions.Contains(_doc.Name(action, "N") ?? ""))
                Add(clause, where, PdfAText.NamedAction(_doc.Name(action, "N")));
            switch (_doc.Resolve(action["Next"]))
            {
                case PdfDictionary next:
                    pending.Push(next);
                    break;
                case PdfArray list when _nextLists.Add(list):
                    foreach (var item in list.Items) pending.Push(item);
                    break;
            }
        }
    }

    private void CheckOutlines()
    {
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<PdfDictionary>();
        if (_doc.Dict(_doc.Dict(_doc.Catalog, "Outlines"), "First") is { } first) stack.Push(first);
        while (stack.Count > 0 && seen.Count < 200_000)
        {
            var item = stack.Pop();
            if (!seen.Add(item)) continue;
            CheckAction(item["A"], PdfAText.Outlines);
            foreach (string key in (ReadOnlySpan<string>)["First", "Next"])
            {
                if (_doc.Dict(item, key) is { } child) stack.Push(child);
            }
        }
    }

    private void CheckForm()
    {
        if (_doc.Dict(_doc.Catalog, "AcroForm") is not { } form) return;
        string clause = C("6.9", "6.4.1");
        if (_doc.Bool(form, "NeedAppearances") == true) Add(clause, PdfAText.Form, PdfAText.NeedAppearances);
        if (form.ContainsKey("XFA")) Add(C("6.9", "6.4.2"), PdfAText.Form, PdfAText.Xfa);
        ScanResources(_doc.Dict(form, "DR"), PdfAText.Form);

        var visited = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<PdfDictionary>();
        foreach (var item in _doc.Array(form, "Fields")?.Items.Take(MaxAnnotations) ?? [])
        {
            if (_doc.Resolve(item) is PdfDictionary root) stack.Push(root);
        }
        while (stack.Count > 0 && visited.Count < 200_000)
        {
            var field = stack.Pop();
            if (!visited.Add(field)) continue;
            if (field.ContainsKey("AA") && Part != 4) Add(C("6.6.2", "6.4.1"), PdfAText.Form, PdfAText.FieldTriggers);
            foreach (var kid in _doc.Array(field, "Kids")?.Items.Take(MaxAnnotations) ?? [])
            {
                if (_doc.Resolve(kid) is PdfDictionary child) stack.Push(child);
            }
        }
    }
}
