namespace LazyPDF.Core;

public sealed partial class PdfRedactor
{
    // Rewrites the matched text in annotation contents and field values; a value that no longer reads as it did when found is left alone.
    // The text found is looked for in the output like any other removed text.
    private Dictionary<int, int> RewriteValues(PdfDocument work, IEnumerable<RedactionValueMatch> values, RedactionOptions options, HashSet<string> needles)
    {
        var counts = new Dictionary<int, int>();
        string replacement = options.OverlayText ?? "";
        var writer = new PdfAnnotationWriter(work, fonts);
        // Annotations are looked up before anything is removed, because a removal shifts the indexes after it.
        var pages = new Dictionary<int, IReadOnlyList<PdfAnnotation>>();
        var targets = new List<(IGrouping<(int Page, int Annotation), RedactionValueMatch> Group, PdfAnnotation Annotation)>();
        foreach (var group in values.Where(v => v.Page >= 0 && v.Page < work.Pages.Count && v.Length > 0).GroupBy(v => (v.Page, v.Annotation)).OrderBy(g => g.Key.Page).ThenBy(g => g.Key.Annotation))
        {
            if (!pages.TryGetValue(group.Key.Page, out var annotations)) pages[group.Key.Page] = annotations = PdfAnnotations.Read(work, work.Pages[group.Key.Page]);
            if (group.Key.Annotation < 0 || group.Key.Annotation >= annotations.Count) continue;
            targets.Add((group, annotations[group.Key.Annotation]));
        }
        foreach (var (group, annotation) in targets)
        {
            var hits = group.OrderByDescending(v => v.Start).ToList();
            bool done = annotation.Type == AnnotationType.Widget ? RewriteField(work, annotation, hits, replacement, needles) : RewriteComment(work, writer, annotation, hits, replacement, needles);
            if (done) counts[group.Key.Page] = counts.GetValueOrDefault(group.Key.Page) + 1;
        }
        return counts;
    }

    private static string? Rewritten(string? current, List<RedactionValueMatch> hits, string replacement)
    {
        if (current is null) return null;
        string text = current;
        int limit = text.Length;
        foreach (var hit in hits)
        {
            if (hit.Text.Length != hit.Length || hit.Start < 0 || hit.Start + hit.Length > limit || string.CompareOrdinal(text, hit.Start, hit.Text, 0, hit.Length) != 0) continue;
            text = string.Concat(text.AsSpan(0, hit.Start), replacement, text.AsSpan(hit.Start + hit.Length));
            limit = hit.Start;
        }
        return text == current ? null : text;
    }

    private static bool RewriteComment(PdfDocument work, PdfAnnotationWriter writer, PdfAnnotation annotation, List<RedactionValueMatch> hits, string replacement, HashSet<string> needles)
    {
        if (Rewritten(annotation.Contents, hits, replacement) is not { } text) return false;
        foreach (var hit in hits) AddNeedle(needles, hit.Text);
        try
        {
            writer.SetContents(annotation, text);
        }
        catch (InvalidOperationException)
        {
            // A free text box that cannot be drawn again with the new text goes whole.
            return writer.Delete(annotation);
        }
        // Rich text and the subject can repeat the words; neither is drawn.
        annotation.Dictionary.Remove("RC");
        if (PdfText.Read(work, annotation.Dictionary, "Subj") is { } subject)
        {
            string changed = hits.Aggregate(subject, (s, hit) => s.Replace(hit.Text, replacement, StringComparison.Ordinal));
            if (changed != subject) annotation.Dictionary["Subj"] = PdfText.ToObject(changed);
        }
        return true;
    }

    private bool RewriteField(PdfDocument work, PdfAnnotation widget, List<RedactionValueMatch> hits, string replacement, HashSet<string> needles)
    {
        var form = PdfForm.Read(work, fonts);
        if (RedactionValues.FieldOf(form, widget.Dictionary) is not { } field || !RedactionValues.IsText(field)) return false;
        if (Rewritten(field.Value, hits, replacement) is not { } text) return false;
        foreach (var hit in hits) AddNeedle(needles, hit.Text);
        try
        {
            if (form.SetValue(field.Name, text).Rejected.Count > 0) form.SetValue(field.Name, "");
        }
        catch (Exception e) when (e is InvalidOperationException or PdfReadException)
        {
            form.Remove(field);
            return true;
        }
        // The default value and the rich value can repeat the words; neither is drawn from the value.
        field.Dictionary.Remove("RV");
        if (field.DefaultValue is { } dv)
        {
            string changed = hits.Aggregate(dv, (s, hit) => s.Replace(hit.Text, replacement, StringComparison.Ordinal));
            if (changed != dv) field.Dictionary["DV"] = PdfText.ToObject(changed);
        }
        return true;
    }
}
