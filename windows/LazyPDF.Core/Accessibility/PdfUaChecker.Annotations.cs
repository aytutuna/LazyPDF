namespace LazyPDF.Core;

// Annotations (ISO 14289-1 7.18): in the tree under the right type, with a description for a reader.
internal sealed partial class PdfUaChecker
{
    private void CheckAnnotations()
    {
        var owners = new Dictionary<int, StructElement>();
        foreach (var element in _tree?.Elements ?? [])
        {
            foreach (var target in element.Kids.OfType<StructObject>()) owners.TryAdd(target.Target.Number, element);
        }

        int budget = 50_000;
        foreach (var page in _doc.Pages)
        {
            cancel.ThrowIfCancellationRequested();
            if (_doc.Array(page.Dictionary, "Annots") is not { Items.Count: > 0 } annotations) continue;
            if (_doc.Name(page.Dictionary, "Tabs") != "S") Add("28-006", "7.18.3", PdfAText.PageName(page.Index + 1), PdfUaText.TabOrder);
            for (int i = 0; i < annotations.Items.Count && --budget >= 0; i++)
            {
                if (_doc.Resolve(annotations.Items[i]) is not PdfDictionary annotation) continue;
                string? subtype = _doc.Name(annotation, "Subtype");
                if (subtype is null or "Popup" or "PrinterMark" or "TrapNet") continue;
                string where = PdfAText.AnnotationName(page.Index + 1, i + 1);
                CheckAnnotation(annotation, subtype, where, annotations.Items[i] is PdfReference reference && owners.TryGetValue(reference.Number, out var owner) ? owner : null);
            }
        }
    }

    private void CheckAnnotation(PdfDictionary annotation, string subtype, string where, StructElement? owner)
    {
        string expected = subtype switch { "Widget" => "Form", "Link" => "Link", _ => "Annot" };
        if (_tree is not null)
        {
            if (owner is null) Add("28-002", "7.18.1", where, PdfUaText.AnnotationUntagged(subtype));
            else if (_tree.StandardType(owner.Type) != expected) Add("28-003", "7.18.1", where, PdfUaText.AnnotationTag(subtype, expected, _tree.StandardType(owner.Type)));
        }
        // The structure element's /Alt stands in for the missing key, except on a Link, whose /Contents 7.18.5 requires itself.
        bool described = !string.IsNullOrWhiteSpace(owner?.Alt);
        if (subtype == "Widget")
        {
            if (!described && !HasTooltip(annotation)) Add("28-005", "7.18.4", where, PdfUaText.WidgetTooltip);
        }
        else if (string.IsNullOrWhiteSpace(PdfText.Read(_doc, annotation, "Contents")) && (subtype == "Link" || !described))
        {
            Add("28-004", subtype == "Link" ? "7.18.5" : "7.18.1", where, PdfUaText.AnnotationContents(subtype));
        }
        if (subtype == "FileAttachment") CheckFileSpec(annotation["FS"]);
    }

    // A widget takes /TU from the field it belongs to.
    private bool HasTooltip(PdfDictionary field)
    {
        for (int hops = 0; hops < 32 && field is not null; hops++)
        {
            if (!string.IsNullOrWhiteSpace(PdfText.Read(_doc, field, "TU"))) return true;
            field = _doc.Dict(field, "Parent")!;
        }
        return false;
    }
}
