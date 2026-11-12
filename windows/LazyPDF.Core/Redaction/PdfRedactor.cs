using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// Removes what is under marks from a document for good. Marking writes /Redact annotations that can
/// be looked over and nothing is removed; applying reads the marks, takes the text, pictures, shapes,
/// annotations and form fields under them out of a copy of the file and covers the places. A page that cannot be
/// followed to its end by the rule in <see cref="RedactionWalk"/> becomes a picture of itself instead.
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
    public RedactionResult ApplyMarked(RedactionOptions? options = null, IEnumerable<RedactionValueMatch>? values = null) => Apply(ReadMarks(), options, values);

    /// <summary>
    /// Removes what is under the marks and returns the new file. A page with marks that is not understood in full, by
    /// the rule in <see cref="RedactionWalk"/>, becomes a picture of itself drawn by <see cref="RedactionOptions.Renderer"/>;
    /// without one, or when it cannot draw the page, this throws <see cref="InvalidOperationException"/> with
    /// <see cref="RedactionText.NeedsPicture"/> or <see cref="RedactionText.NotDrawn"/>. It throws the same with
    /// <see cref="RedactionText.NoFont"/> when overlay text needs a font that cannot be found. The document is not
    /// changed in any case. <paramref name="values"/> are hits in annotation contents and field values (see
    /// <see cref="RedactionFinder.FindInValues"/>): the text found is replaced by <see cref="RedactionOptions.OverlayText"/>, or
    /// removed without one, and the appearance is drawn again.
    /// </summary>
    public RedactionResult Apply(IEnumerable<RedactionMark> marks, RedactionOptions? options = null, IEnumerable<RedactionValueMatch>? values = null)
    {
        options ??= new RedactionOptions();
        var chosen = marks.Where(m => m.Page >= 0 && m.Page < document.Pages.Count)
            .Select(m => m with { Quads = [.. m.Quads.Where(q => double.IsFinite(q.X0 + q.Y0 + q.X1 + q.Y1 + q.X2 + q.Y2 + q.X3 + q.Y3))] })
            .Where(m => m.Quads.Count > 0).ToList();
        using var work = PdfDocument.Open(document.SaveRewrite());
        PushDownResources(work);

        var pages = new List<PageRedaction>();
        var needles = new HashSet<string>(StringComparer.Ordinal);
        // First, since removing annotations under a mark shifts the indexes the hits were found at.
        var rewritten = values is null ? [] : RewriteValues(work, values, options, needles);

        PdfDrawFont? font = null;
        var texts = chosen.Select(m => m.OverlayText ?? options.OverlayText).Where(t => !string.IsNullOrEmpty(t)).Select(t => t!).ToList();
        if (texts.Count > 0)
        {
            font = new PdfFontEmbedder(work, fonts).Add(options.FontFamily, FontStyles.Bold, texts)
                   ?? throw new InvalidOperationException(RedactionText.NoFont);
        }

        var tagged = new Dictionary<int, Dictionary<int, (int Total, int Removed)>>();
        var rewriter = new ContentRewriter(work, new ImageRedactor(work, images));
        var interpreter = new ContentInterpreter(work) { WalkPatterns = false };
        var plans = chosen.GroupBy(m => m.Page).OrderBy(g => g.Key).Select(g => Examine(work, work.Pages[g.Key], [.. g], interpreter, needles)).ToList();
        plans = Reconcile(plans);
        if (options.FlattenMarkedPages) plans = [.. plans.Select(p => p with { Understood = false })];
        if (options.Renderer is null && plans.FirstOrDefault(p => !p.Understood) is { } stuck) throw new InvalidOperationException(RedactionText.NeedsPicture(stuck.Page.Index));

        // What the marked pages reach now is all emptied at the end except what they still paint.
        var reached = new HashSet<int>();
        foreach (var plan in plans) reached.UnionWith(plan.Reach);
        var painted = new HashSet<int>();
        var flattened = new List<int>();
        foreach (var plan in plans)
        {
            pages.Add(RedactPage(work, plan, options, font, rewriter, needles, painted, flattened, out var counts));
            tagged[plan.Page.Reference.Number] = counts;
        }
        foreach (var (page, (count, whole)) in rewritten)
        {
            int at = pages.FindIndex(p => p.Page == page);
            if (at >= 0) pages[at] = pages[at] with { Values = count, ValuesWhole = whole };
            else pages.Add(new PageRedaction(page, 0, 0, 0, 0, 0, count, ValuesWhole: whole));
        }
        pages.Sort((a, b) => a.Page.CompareTo(b.Page));
        var marked = plans.Select(p => p.Page.Index).ToHashSet();
        var unfollowed = new List<int>();
        if (reached.Count > 0)
        {
            foreach (var page in work.Pages.Where(p => !marked.Contains(p.Index)))
            {
                if (!Keep(work, page, reached, painted)) unfollowed.Add(page.Index);
            }
        }

        int signatures = RemoveSignatures(work);
        CleanForm(work);
        RedactionStructure.Prune(work, tagged, rewriter.Replaced, [.. flattened.Select(i => work.Pages[i].Reference.Number)]);
        RedactionObjects.Sweep(work, reached, painted);
        var findings = RedactionMetadata.Scan(work, needles, options.ChangeMetadata);

        // The check reads the file as plain bytes; encrypting changes nothing it looks at. An open file gets an /ID
        // of its own, so that it is not tied to the original; the keys of an encrypted one are made from the first.
        byte[] bytes = work.SaveRewrite(new PdfSaveOptions(DocumentId: RandomNumberGenerator.GetBytes(16)));
        var verification = Verify(bytes, chosen, needles, texts.Distinct().ToList());
        if (unfollowed.Count > 0) verification = new RedactionVerification([.. verification.Problems, .. unfollowed.Select(RedactionText.NotFollowed)]);
        if (options.KeepEncryption && document.Security is { } security)
        {
            bytes = work.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: document.FirstId ?? []));
        }
        var report = new RedactionReport(pages, findings, signatures, options.IncludeText ? [.. needles.Order(StringComparer.Ordinal)] : []) { Flattened = flattened };
        return new RedactionResult(bytes, report, verification);
    }

    // A page without marks keeps what it paints of the objects a redacted page reached; what it only lists is not its own.
    // A page that cannot be followed keeps every stream it lists, but not what its keys happen to name, and the result says it was not checked.
    private static bool Keep(PdfDocument work, PdfPage page, HashSet<int> reached, HashSet<int> painted)
    {
        var all = new HashSet<int>();
        RedactionObjects.Collect(work, page.Dictionary, all);
        if (!all.Overlaps(reached)) return true;
        var first = new RedactionWalk(work);
        if (!first.Page(page))
        {
            RedactionObjects.Painted(work, page.Dictionary, painted, RedactionObjects.Listing);
            return false;
        }
        // Its own lists, so that the ones it shared with a redacted page are not held by it.
        RedactionResources.Rebuild(work, page.Dictionary, first);
        var walk = new RedactionWalk(work);
        walk.Page(page);
        return KeepPainted(work, page, walk, painted);
    }

    // False when an appearance cannot be followed: the page then keeps every stream its annotations list, and the result says so.
    private static bool KeepPainted(PdfDocument work, PdfPage page, RedactionWalk walk, HashSet<int> painted)
    {
        bool followed = walk.Annotations(page);
        if (!followed) RedactionObjects.Painted(work, page.Dictionary["Annots"], painted, RedactionObjects.Listing);
        painted.UnionWith(walk.Used);
        RedactionObjects.PaintedStream(work, page.Dictionary["Contents"], painted, RedactionObjects.Painting);
        RedactionObjects.Painted(work, page.Dictionary["Group"], painted, RedactionObjects.Painting);
        KeepBoxes(work, page, painted);
        return followed;
    }

    // The boxes and the turn can be objects of their own, shared with pages that were not redacted.
    private static void KeepBoxes(PdfDocument work, PdfPage page, HashSet<int> painted)
    {
        foreach (string key in (ReadOnlySpan<string>)["MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate", "UserUnit"])
        {
            RedactionObjects.Painted(work, page.Dictionary[key], painted, RedactionObjects.Painting);
        }
    }

    // Resources a page takes from the page tree stay in the tree node, and with them the pictures
    // that are cut on the page. Every page gets its own reference and the nodes lose theirs.
    private static void PushDownResources(PdfDocument work)
    {
        const int MaxDepth = 256;
        var nodes = new List<PdfDictionary>();
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        // Down from the root by /Kids, as the page list is read, since a /Parent can be missing or point elsewhere.
        void Down(PdfObject? node, PdfObject? inherited, int depth)
        {
            if (work.Resolve(node) is not PdfDictionary dictionary || depth > MaxDepth || !seen.Add(dictionary)) return;
            inherited = dictionary["Resources"] ?? inherited;
            // A node is told as the page list tells it: /Type /Page is a page, whatever else it holds.
            if (work.Name(dictionary, "Type") != "Page" && work.Resolve(dictionary["Kids"]) is PdfArray kids)
            {
                nodes.Add(dictionary);
                foreach (var kid in kids.Items) Down(kid, inherited, depth + 1);
            }
            else if (!dictionary.ContainsKey("Resources") && inherited is not null)
            {
                dictionary["Resources"] = inherited;
            }
        }
        Down(work.Catalog["Pages"], null, 0);
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
