using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// Removes what is under marks from a document for good. Marking writes /Redact annotations that can
/// be looked over and nothing is removed; applying reads the marks, takes the text, pictures, shapes,
/// annotations and form fields under them out of a copy of the file and covers the places.
/// The result is always a new file written whole (<see cref="PdfDocument.SaveRewrite"/>): an earlier
/// revision of the same file would still hold what was removed, so the document itself is not
/// changed and there is no way to apply by appending.
/// </summary>
public sealed partial class PdfRedactor(PdfDocument document, IFontSource? fonts = null, IImageCodec? images = null)
{
    /// <summary>The marks the document holds as /Redact annotations, in page order.</summary>
    public IReadOnlyList<RedactionMark> ReadMarks()
    {
        var marks = new List<RedactionMark>();
        foreach (var a in PdfAnnotations.ReadAll(document).Where(a => a.Type == AnnotationType.Redact))
        {
            var quads = a.Quads.Count > 0
                ? a.Quads.Select(q => new TextQuad(q.X3, q.Y3, q.X4, q.Y4, q.X2, q.Y2, q.X1, q.Y1)).ToList()
                : RedactionMark.FromRect(a.PageIndex, a.Rect).Quads.ToList();
            double[]? fill = a.InteriorColor is { Count: 1 or 3 or 4 } c ? [.. c] : null;
            marks.Add(new RedactionMark(a.PageIndex, quads, fill, PdfText.Read(document, a.Dictionary, "OverlayText")));
        }
        return marks;
    }

    /// <summary>Writes a /Redact annotation for each mark. The edit session commits them; nothing is removed.</summary>
    public IReadOnlyList<PdfAnnotation> AddMarks(IEnumerable<RedactionMark> marks, AnnotationInfo? info = null)
    {
        var writer = new PdfAnnotationWriter(document, fonts);
        var added = new List<PdfAnnotation>();
        foreach (var mark in marks)
        {
            if (mark.Page < 0 || mark.Page >= document.Pages.Count || mark.Quads.Count == 0) continue;
            var quads = mark.Quads.Select(q => new MarkupQuad(q.X3, q.Y3, q.X2, q.Y2, q.X0, q.Y0, q.X1, q.Y1)).ToList();
            added.Add(writer.AddRedact(document.Pages[mark.Page], quads, info, mark.Fill, mark.OverlayText));
        }
        return added;
    }

    /// <summary>Applies the document's own /Redact annotations.</summary>
    public RedactionResult ApplyMarked(RedactionOptions? options = null) => Apply(ReadMarks(), options);

    /// <summary>
    /// Removes what is under the marks and returns the new file. Throws <see cref="InvalidOperationException"/>
    /// with <see cref="RedactionText.NoFont"/> when overlay text needs a font that cannot be found; the
    /// document is not changed in any case.
    /// </summary>
    public RedactionResult Apply(IEnumerable<RedactionMark> marks, RedactionOptions? options = null)
    {
        options ??= new RedactionOptions();
        var chosen = marks.Where(m => m.Page >= 0 && m.Page < document.Pages.Count && m.Quads.Count > 0).ToList();
        using var work = PdfDocument.Open(document.SaveRewrite());
        PushDownResources(work);

        PdfDrawFont? font = null;
        var texts = chosen.Select(m => m.OverlayText ?? options.OverlayText).Where(t => !string.IsNullOrEmpty(t)).Select(t => t!).ToList();
        if (texts.Count > 0)
        {
            font = new PdfFontEmbedder(work, fonts).Add(options.FontFamily, FontStyles.Bold, texts)
                   ?? throw new InvalidOperationException(RedactionText.NoFont);
        }

        var pages = new List<PageRedaction>();
        var needles = new HashSet<string>(StringComparer.Ordinal);
        var tagged = new Dictionary<int, Dictionary<int, (int Total, int Removed)>>();
        var dropped = new HashSet<object>(ReferenceEqualityComparer.Instance);
        var rewriter = new ContentRewriter(work, new ImageRedactor(work, images));
        var interpreter = new ContentInterpreter(work) { WalkPatterns = false };
        foreach (var group in chosen.GroupBy(m => m.Page).OrderBy(g => g.Key))
        {
            var page = work.Pages[group.Key];
            var done = RedactPage(work, page, [.. group], options, font, rewriter, interpreter, needles, dropped, out var counts);
            pages.Add(done);
            tagged[page.Reference.Number] = counts;
        }

        dropped.UnionWith(rewriter.Replaced);
        var unused = RedactionPrune.Run(work, dropped);
        int signatures = RemoveSignatures(work);
        CleanForm(work);
        RedactionStructure.Prune(work, tagged, [.. dropped.OfType<PdfStream>()]);
        RedactionPrune.Scrub(work, unused);
        var findings = RedactionMetadata.Scan(work, needles, options.ChangeMetadata);

        // The check reads the file as plain bytes; encrypting changes nothing it looks at. An open file gets an /ID
        // of its own, so that it is not tied to the original; the keys of an encrypted one are made from the first.
        byte[] bytes = work.SaveRewrite(new PdfSaveOptions(DocumentId: RandomNumberGenerator.GetBytes(16)));
        var verification = Verify(bytes, chosen, needles, texts.Distinct().ToList());
        if (options.KeepEncryption && document.Security is { } security)
        {
            bytes = work.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: document.FirstId ?? []));
        }
        var report = new RedactionReport(pages, findings, signatures, options.IncludeText ? [.. needles.Order(StringComparer.Ordinal)] : []);
        return new RedactionResult(bytes, report, verification);
    }

    // Resources a page takes from the page tree stay in the tree node, and with them the pictures
    // that are cut on the page. Every page gets its own reference and the nodes lose theirs.
    private static void PushDownResources(PdfDocument work)
    {
        const int MaxDepth = 64;
        var nodes = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (var page in work.Pages)
        {
            bool own = page.Dictionary.ContainsKey("Resources");
            var node = work.Dict(page.Dictionary, "Parent");
            for (int depth = 0; node is not null && depth < MaxDepth; depth++, node = work.Dict(node, "Parent"))
            {
                nodes.Add(node);
                if (own || node["Resources"] is not { } inherited) continue;
                page.Dictionary["Resources"] = inherited;
                own = true;
            }
        }
        foreach (var node in nodes) node.Remove("Resources");
    }

    // A signature covers bytes that no longer exist in the output.
    private static int RemoveSignatures(PdfDocument work)
    {
        int count = 0;
        bool signed = work.IsSigned;
        foreach (int number in work.ObjectNumbers)
        {
            if (work.Get(number) is PdfDictionary field && work.Name(field, "FT") == "Sig" && field.ContainsKey("V"))
            {
                field.Remove("V");
                count++;
            }
        }
        work.Catalog.Remove("Perms");
        work.Catalog.Remove("DSS");
        work.Dict(work.Catalog, "AcroForm")?.Remove("SigFlags");
        return count == 0 && signed ? 1 : count;
    }

    // Values live in the XFA data too, and a form with no field left has nothing to say.
    private static void CleanForm(PdfDocument work)
    {
        if (work.Dict(work.Catalog, "AcroForm") is not { } form) return;
        if (work.Array(form, "Fields") is { Items.Count: 0 }) work.Catalog.Remove("AcroForm");
        else if (work.HasXfa && work.Catalog.ContainsKey("AcroForm")) form.Remove("XFA");
    }
}
