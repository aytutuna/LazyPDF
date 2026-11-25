namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    /// <summary>
    /// Burns the widgets of the fields (all fields when null) into their pages' content as the
    /// annotation flattener does (ISO 32000-1 12.5.5), takes the fields out of the form, and removes
    /// /AcroForm when none is left. A widget that is hidden shows nothing and is dropped without a trace.
    /// A field whose appearance is missing, or all of them when /NeedAppearances is set, is drawn first
    /// from its value; one that cannot be drawn (no font for its text) is burned as it is. Returns the
    /// number of widgets burned in.
    /// </summary>
    public int Flatten(IEnumerable<FormField>? fields = null)
    {
        RequireFillable();
        var chosen = (fields ?? _fields).ToList();
        RegenerateStale(chosen);

        var widgets = new HashSet<PdfDictionary>(chosen.SelectMany(f => Current(f)?.Widgets ?? f.Widgets).Select(w => w.Dictionary), ReferenceEqualityComparer.Instance);
        int burned = 0;
        foreach (var page in _document.Pages)
        {
            burned += PdfAnnotationFlattener.Flatten(_document, page, a => widgets.Contains(a.Dictionary));
        }
        foreach (var field in chosen)
        {
            foreach (var widget in Current(field)?.Widgets ?? field.Widgets) TakeFromPages(widget);
            RemoveField(Current(field) ?? field);
        }

        if (_fields.All(f => chosen.Any(c => ReferenceEquals(c.Dictionary, f.Dictionary))))
        {
            bool hadXfa = _document.HasXfa;
            _document.Catalog.Remove("AcroForm");
            XfaRemoved |= hadXfa;
        }
        else DropXfa();
        Refresh();
        return burned;
    }

    // Draws the fields whose appearance is missing, or all of them under /NeedAppearances; one that cannot be drawn keeps what it has.
    internal void RegenerateStale(IEnumerable<FormField> fields)
    {
        RequireFillable();
        bool stale = NeedAppearances;
        foreach (var field in fields)
        {
            if (field.Kind == FieldKind.Signature) continue;
            if (!stale && field.Widgets.All(w => _document.Dict(w.Dictionary, "AP")?["N"] is not null)) continue;
            try
            {
                Regenerate([field]);
            }
            catch (InvalidOperationException)
            {
            }
        }
    }

    /// <summary>The fields of <paramref name="document"/> drawn afresh where their appearance is missing or /NeedAppearances is set.</summary>
    internal static void RegenerateStale(PdfDocument document)
    {
        var form = Read(document);
        form.RegenerateStale(form.Fields);
    }
}
