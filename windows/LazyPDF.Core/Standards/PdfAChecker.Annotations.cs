namespace LazyPDF.Core;

// Annotations, actions and interactive forms (ISO 19005-1 6.5, 6.6, 6.9; 19005-2 6.3, 6.4, 6.5).
internal sealed partial class PdfAChecker
{
    private const int MaxAnnotations = 50_000;
    private const int MaxActionDepth = 16;

    private static readonly string[] Part1Annotations =
        ["Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Ink", "Popup", "Widget", "PrinterMark", "TrapNet"];

    private static readonly string[] LaterAnnotations = [.. Part1Annotations, "Caret", "FileAttachment", "Redact", "Watermark"];

    internal static readonly string[] ForbiddenActions = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "JavaScript", "Hide", "SetOCGState", "Rendition", "Trans", "GoTo3DView"];

    internal static readonly string[] NamedActions = ["NextPage", "PrevPage", "FirstPage", "LastPage"];

    /// <summary>The annotation subtypes a part allows, before the rule about attachments.</summary>
    internal static string[] AllowedAnnotations(int part) => part == 1 ? Part1Annotations : LaterAnnotations;

    private void CheckAnnotations(PdfPage page, int pageNumber, ContentInterpreter interpreter)
    {
        if (_doc.Array(page.Dictionary, "Annots") is not { } annotations) return;
        string flags = C("6.5.3", "6.3.2"), appearance = C("6.5.3", "6.3.3");
        for (int i = 0; i < annotations.Items.Count && i < MaxAnnotations; i++)
        {
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
            CheckAction(annotation["A"], where, 0);
            CheckTriggers(annotation, where, subtype == "Widget");

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
        foreach (var stream in streams)
        {
            CheckFormStream(stream, where);
            try
            {
                interpreter.Run(stream, new Visitor(this, where));
            }
            catch (PdfReadException)
            {
                Add("6.1.7", where, PdfAText.ContentUnreadable);
            }
        }
    }

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

    private void CheckTriggers(PdfDictionary owner, string where, bool field)
    {
        if (_doc.Dict(owner, "AA") is not { } triggers) return;
        if (field) Add(C("6.6.2", "6.5.2"), where, PdfAText.FieldTriggers);
        foreach (var (_, action) in triggers.Entries.Take(64)) CheckAction(action, where, 0);
    }

    private void CheckAction(PdfObject? value, string where, int depth)
    {
        if (depth > MaxActionDepth || _doc.Resolve(value) is not PdfDictionary action) return;
        string? type = _doc.Name(action, "S");
        string clause = C("6.6.1", "6.5.1");
        if (type is not null && ForbiddenActions.Contains(type)) Add(clause, where, type == "JavaScript" ? PdfAText.JavaScript : PdfAText.ForbiddenAction(type));
        else if (type == "Named" && !NamedActions.Contains(_doc.Name(action, "N") ?? ""))
            Add(clause, where, PdfAText.NamedAction(_doc.Name(action, "N")));
        switch (_doc.Resolve(action["Next"]))
        {
            case PdfDictionary next:
                CheckAction(next, where, depth + 1);
                break;
            case PdfArray list:
                foreach (var item in list.Items.Take(64)) CheckAction(item, where, depth + 1);
                break;
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
            if (field.ContainsKey("AA")) Add(C("6.6.2", "6.5.2"), PdfAText.Form, PdfAText.FieldTriggers);
            foreach (var kid in _doc.Array(field, "Kids")?.Items.Take(MaxAnnotations) ?? [])
            {
                if (_doc.Resolve(kid) is PdfDictionary child) stack.Push(child);
            }
        }
    }
}
