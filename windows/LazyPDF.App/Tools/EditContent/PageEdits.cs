using System.Text.RegularExpressions;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

/// <summary>What an edit came to: why Core refused it, or what the person should know about one that went through.</summary>
internal sealed record EditOutcome(bool Done, string? Problem = null, string? Note = null);

/// <summary>The file a replace-all made on its copy, and the length of the file it started from.</summary>
internal sealed record Replacement(int StartLength, ReplaceReport Report, byte[] File);

/// <summary>
/// The edits of the panel, each a call to Core's page editor. Objects are named by their id on the page so that a
/// call after an undo reads them again instead of holding stale ones. The page editor commits on the session itself,
/// so a change that went through is shown by <see cref="DocumentTab.Refresh"/>.
/// </summary>
internal sealed class PageEdits(DocumentTab tab, IFontSource fonts, IImageCodec codec)
{
    private readonly Dictionary<int, PageEditor> _editors = [];

    public PageEditor Editor(int page)
    {
        if (!_editors.TryGetValue(page, out var editor)) _editors[page] = editor = new PageEditor(tab.Session, page, fonts, codec);
        return editor;
    }

    public PageObject? Object(int page, int id) => id >= 0 && id < Editor(page).Objects.Count ? Editor(page).Objects[id] : null;

    public IReadOnlyList<PageObject> Objects(int page, IEnumerable<int> ids) => [.. ids.Select(id => Object(page, id)).OfType<PageObject>()];

    // ----- Text

    public EditOutcome ReplaceLine(int page, TextObjectLine line, string text) =>
        Result(Editor(page).ReplaceText(line.Range, text));

    public EditOutcome ReplaceParagraph(int page, int block, string text) =>
        Object(page, block) is TextObject o ? Result(Editor(page).ReplaceParagraph(o, text)) : Stale();

    // Core restyles the ranges it is given and sets a changed font again from their text, so a range over several lines
    // would come back as one; each line goes on its own.
    public EditOutcome Style(int page, int block, TextStyleChange change)
    {
        if (Object(page, block) is not TextObject o) return Stale();
        if (change.Size is { } size) change = change with { Size = size * Unscaled(o) };
        return Result(Editor(page).SetTextStyle(o.Lines.Count > 0 ? o.Lines.Select(l => l.Range) : [o.Range], change));
    }

    // The size shown is in page units; Tf takes it before Tm and cm scale it.
    private static double Unscaled(TextObject o)
    {
        var glyph = o.Glyphs.FirstOrDefault(g => g.Text.Any(c => !char.IsWhiteSpace(c))) ?? o.Glyphs.FirstOrDefault();
        return glyph is null || glyph.UserSize <= 0 ? 1 : glyph.FontSize / glyph.UserSize;
    }

    public EditOutcome Align(int page, int block, TextAlignment alignment) =>
        Object(page, block) is TextObject o ? Result(Editor(page).SetAlignment(o, alignment)) : Stale();

    public EditOutcome Space(int page, int block, double spacing) =>
        Object(page, block) is TextObject o ? Result(Editor(page).SetLineSpacing(o, spacing)) : Stale();

    public EditOutcome AddTextBox(int page, PdfRect box, string text, TextBoxStyle style) =>
        Result(Editor(page).AddTextBox(box, text, style));

    public EditOutcome AddImage(int page, PdfRect box, byte[] file) =>
        Result(Editor(page).AddImage(box, file));

    // ----- Objects

    public EditOutcome Move(int page, IEnumerable<int> ids, double dx, double dy) =>
        Result(Editor(page).Move(Objects(page, ids), dx, dy));

    public EditOutcome Resize(int page, IEnumerable<int> ids, PdfRect bounds) =>
        Result(Editor(page).Resize(Objects(page, ids), bounds));

    public EditOutcome Rotate(int page, IEnumerable<int> ids, double degrees) =>
        Result(Editor(page).Rotate(Objects(page, ids), degrees));

    // Core mirrors in page space; on a page turned a quarter, by /Rotate or by the viewer, that is the other way round on the screen.
    public EditOutcome Flip(int page, IEnumerable<int> ids, bool acrossScreen, int viewRotation)
    {
        int turned = new PageGeometry(tab.Document.Pages[page]).Rotation + viewRotation;
        return Result(Editor(page).Flip(Objects(page, ids), acrossScreen != (turned / 90 % 2 == 1)));
    }

    public EditOutcome Delete(int page, IEnumerable<int> ids) =>
        Result(Editor(page).Delete(Objects(page, ids)));

    public EditOutcome Opacity(int page, IEnumerable<int> ids, double opacity) =>
        Result(Editor(page).SetOpacity(Objects(page, ids), opacity));

    public EditOutcome Order(int page, int id, OrderMove move) =>
        Object(page, id) is { } o ? Result(Editor(page).Order(o, move)) : Stale();

    // Core sets colours round the paint the shape already has, so a fill on a line-only shape would change nothing.
    public EditOutcome PathStyle(int page, IEnumerable<int> ids, RgbColor? fill, RgbColor? stroke, double? width)
    {
        var paths = Objects(page, ids).OfType<PathObject>().Where(p => (fill is null || p.Fill) && ((stroke is null && width is null) || p.Stroke)).ToList();
        if (paths.Count == 0) return new EditOutcome(false, fill is not null ? Loc.T("This shape has no fill. Use the line colour instead.") : Loc.T("This shape has no line. Use the fill colour instead."));
        return Result(Editor(page).SetPathStyle(paths, fill, stroke, width));
    }

    public EditOutcome Crop(int page, int id, PdfRect area) =>
        Object(page, id) is ImageObject o ? Result(Editor(page).Crop(o, area)) : Stale();

    public EditOutcome ReplaceImage(int page, int id, byte[] file) =>
        Object(page, id) is ImageObject o ? Result(Editor(page).ReplaceImage(o, file)) : Stale();

    public ExtractedImage? Extract(int page, int id) =>
        Object(page, id) is ImageObject o ? Editor(page).ExtractImage(o) : null;

    // ----- Replace all

    /// <summary>
    /// Replaces on a copy of the file, which holds nothing of the document being shown, so it can run off the UI thread
    /// and be cancelled without leaving half an edit behind. <see cref="Adopt"/> brings the result in.
    /// </summary>
    public Replacement ReplaceAll(byte[] start, string query, string replacement, TextSearchOptions options, CancellationToken cancel)
    {
        var scratch = tab.Certificate is { } certificate ? PdfEditSession.Open(start, certificate) : PdfEditSession.Open(start, tab.Password);
        var report = TextReplacer.ReplaceAll(scratch, query, replacement, options, fonts, Loc.T("Replace text"), cancel);
        return new Replacement(start.Length, report, report.Replaced > 0 ? scratch.Current.ToArray() : []);
    }

    /// <summary>Makes the replaced copy the document as one undo step, unless the document moved on while it was made.</summary>
    public EditOutcome Adopt(Replacement made)
    {
        if (made.Report.Replaced == 0) return Report(made.Report);
        try
        {
            if (tab.Session.Current.Length != made.StartLength) throw new ArgumentException("The document changed.");
            tab.Session.CommitBytes(Loc.T("Replace text"), made.File);
        }
        catch (ArgumentException)
        {
            return new EditOutcome(false, Loc.T("The file changed meanwhile. Replace again."));
        }
        tab.Refresh();
        return Report(made.Report);
    }

    public void Refresh() => tab.Refresh();

    private static EditOutcome Report(ReplaceReport report)
    {
        string? why = report.Failed.Count > 0 ? report.Failed[0].Reason : null;
        if (report.Replaced == 0) return new EditOutcome(false, why ?? Loc.T("Nothing found to replace."));
        string done = Loc.Plural(report.Replaced, "Replaced {0} time.", "Replaced {0} times.");
        string? left = report.Failed.Count == 0 ? null : Loc.Plural(report.Failed.Count, "{0} match was left as it was: {1}", "{0} matches were left as they were: {1}", why);
        return new EditOutcome(true, null, left is null ? done : done + " " + left);
    }

    // ----- Links

    public IReadOnlyList<PdfLink> Links(int page) => PdfLinks.Read(tab.Document, tab.Document.Pages[page]);

    /// <summary>Adds a link over <paramref name="area"/>, or points <paramref name="old"/> somewhere else when it is given.</summary>
    public EditOutcome SetLink(int page, PdfRect area, PdfAction target, PdfLink? old)
    {
        var document = tab.Document;
        var p = document.Pages[page];
        if (old is null) PdfLinks.Add(document, p, area, target);
        else if (Annotation(document, p, old) is { } annot)
        {
            annot.Remove("Dest");
            annot["A"] = PdfActions.ToObject(document, target);
        }
        else return new EditOutcome(false, EditingText.StaleObject);
        return tab.Commit(old is null ? Loc.T("Add link") : Loc.T("Change link")) ? new EditOutcome(true) : new EditOutcome(false, EditingText.NothingChanged);
    }

    public EditOutcome RemoveLink(int page, PdfLink link)
    {
        var document = tab.Document;
        var p = document.Pages[page];
        bool removed = link.Reference is { } reference
            ? PdfLinks.Remove(document, p, reference)
            : Annotation(document, p, link) is { } annot && document.Array(p.Dictionary, "Annots") is { } annots && annots.Items.RemoveAll(i => ReferenceEquals(i, annot)) > 0;
        if (!removed) return new EditOutcome(false, EditingText.NothingChanged);
        return tab.Commit(Loc.T("Remove link")) ? new EditOutcome(true) : new EditOutcome(false, EditingText.NothingChanged);
    }

    // The dictionary of a link, edited where it is so that its border, colour and place in the list stay; a link given
    // directly in /Annots has no reference and is found by its rectangle.
    private static PdfDictionary? Annotation(PdfDocument document, PdfPage page, PdfLink link)
    {
        if (link.Reference is { } reference) return document.Resolve(reference) as PdfDictionary;
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return null;
        return annots.Items.OfType<PdfDictionary>().FirstOrDefault(a => document.Name(a, "Subtype") == "Link" && document.Rect(a, "Rect") == link.Rect);
    }

    /// <summary>A web address or a page number, as typed; null when it is neither.</summary>
    public static PdfAction? Target(bool toPage, string text, int pageCount)
    {
        text = text.Trim();
        if (toPage) return int.TryParse(text, out int n) && n >= 1 && n <= pageCount ? new GoToAction(new PdfDestination(n - 1)) : null;
        if (text.Length == 0 || text.Contains(' ')) return null;
        return new UriAction(Regex.IsMatch(text, @"^(\w+://|mailto:|tel:)", RegexOptions.IgnoreCase) ? text : "https://" + text);
    }

    // ----- Results

    private EditOutcome Result(TextEditResult result)
    {
        if (!result.Done) return new EditOutcome(false, result.Problem);
        tab.Refresh();
        string? note = result.Overlaps ? Loc.T("The new text runs into other text.")
            : result.Grew ? Loc.T("The paragraph grew. Text below stayed put.")
            : result.Substitutions.Count > 0 ? Loc.T("Some letters use {0}.", string.Join(", ", result.Substitutions.Select(s => s.Replacement).Distinct()))
            : null;
        return new EditOutcome(true, null, note);
    }

    private EditOutcome Result(ObjectEditResult result)
    {
        string? skipped = result.Skipped.Count > 0 ? result.Skipped[0].Reason : null;
        if (!result.Done) return new EditOutcome(false, skipped ?? EditingText.NothingChanged);
        tab.Refresh();
        return new EditOutcome(true, null, skipped is null ? null : Loc.T("Some objects were left as they were: {0}", skipped));
    }

    private static EditOutcome Stale() => new(false, EditingText.StaleObject);
}
