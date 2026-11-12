namespace LazyPDF.Core;

/// <summary>The text of annotations and form fields, which is not page text: where finders look and what applying rewrites.</summary>
internal static class RedactionValues
{
    public static IEnumerable<(int Page, int Annotation, RedactionValueSource Source, string Text)> Read(PdfDocument document)
    {
        PdfForm? form = null;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        for (int p = 0; p < document.Pages.Count; p++)
        {
            var annotations = PdfAnnotations.Read(document, document.Pages[p]);
            for (int i = 0; i < annotations.Count; i++)
            {
                var a = annotations[i];
                if (a.Type != AnnotationType.Widget)
                {
                    if (!string.IsNullOrEmpty(a.Contents)) yield return (p, i, RedactionValueSource.Comment, a.Contents);
                    continue;
                }
                form ??= PdfForm.Read(document);
                var field = FieldOf(form, a.Dictionary);
                if (field is null || !IsText(field) || !seen.Add(field.Dictionary) || string.IsNullOrEmpty(field.Value)) continue;
                yield return (p, i, RedactionValueSource.Field, field.Value);
            }
        }
    }

    public static FormField? FieldOf(PdfForm form, PdfDictionary widget) =>
        form.Fields.FirstOrDefault(f => f.Widgets.Any(w => ReferenceEquals(w.Dictionary, widget)));

    public static bool IsText(FormField field) => field.Kind == FieldKind.Text || (field.Kind == FieldKind.ComboBox && field.Has(FieldFlags.Edit));
}
