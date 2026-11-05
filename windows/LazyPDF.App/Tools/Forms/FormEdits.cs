using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

/// <summary>Changes to the form of a tab, each one undoable step. Core's exceptions pass through to the caller.</summary>
internal static class FormEdits
{
    public static PdfForm Read(DocumentTab tab, IFontSource fonts) => PdfForm.Read(tab.Document, fonts);

    // A refused edit may have changed the document before it threw; those changes go, so they do not ride into the next step.
    public static T Apply<T>(DocumentTab tab, IFontSource fonts, string label, Func<PdfForm, T> edit)
    {
        try
        {
            var result = edit(Read(tab, fonts));
            tab.Commit(label);
            return result;
        }
        catch
        {
            tab.Session.Discard();
            throw;
        }
    }

    // The commit tells the window, so it stays on the UI thread; only the edit leaves it. The edit works on the
    // document of the session, so when an undo swapped that document meanwhile, the work is lost and says so.
    public static async Task<T> ApplyAsync<T>(DocumentTab tab, IFontSource fonts, string label, Func<PdfForm, T> edit, CancellationToken token = default)
    {
        var document = tab.Document;
        try
        {
            var form = Read(tab, fonts);
            var result = await Task.Run(() => edit(form), CancellationToken.None);
            if (!ReferenceEquals(document, tab.Document)) throw new InvalidOperationException(Loc.T("The file changed meanwhile. Run it again."));
            token.ThrowIfCancellationRequested();
            tab.Commit(label);
            return result;
        }
        catch when (ReferenceEquals(document, tab.Document))
        {
            tab.Session.Discard();
            throw;
        }
    }

    /// <summary>The proposals of the detector for the whole file, read from a copy so the work can leave the UI thread. Scanned pages are drawn and read from their pixels.</summary>
    public static IReadOnlyList<FieldProposal> Detect(DocumentTab tab, CancellationToken token = default)
    {
        byte[] bytes = tab.Session.Current.ToArray();
        var copy = tab.Certificate is { } certificate ? PdfDocument.Open(bytes, certificate) : PdfDocument.Open(bytes, tab.Password);
        return FieldDetector.Detect(copy, tab.Renderer, token);
    }

    public static string NewName(PdfForm form, FieldKind kind)
    {
        string stem = kind switch
        {
            FieldKind.Text => "Text",
            FieldKind.CheckBox => "Check",
            FieldKind.Radio => "Radio",
            FieldKind.PushButton => "Button",
            FieldKind.ComboBox => "Combo",
            FieldKind.ListBox => "List",
            _ => "Signature",
        };
        for (int n = 1; ; n++)
        {
            if (form.Find(stem + n) is null) return stem + n;
        }
    }

    /// <summary>Points, for a field drawn with a click instead of a drag.</summary>
    public static (double Width, double Height) DefaultSize(FieldKind kind) => kind switch
    {
        FieldKind.CheckBox or FieldKind.Radio => (14, 14),
        FieldKind.ListBox => (150, 60),
        FieldKind.PushButton => (100, 24),
        FieldKind.Signature => (180, 40),
        _ => (150, 20),
    };

    /// <summary>
    /// Adds a field of <paramref name="kind"/>. A radio button joins the group <paramref name="group"/> names, or the
    /// selected radio group when that is empty, and starts a group of that name when there is none yet.
    /// Returns the field's name and the index of the new widget.
    /// </summary>
    public static (string Name, int Widget) Add(PdfForm form, FieldKind kind, int page, PdfRect rect, FormField? selected, string group = "")
    {
        string? named = kind == FieldKind.Radio && group.Trim().Length > 0 ? group.Trim() : null;
        if (kind == FieldKind.Radio && (named is null ? selected : form.Find(named)) is { Kind: FieldKind.Radio } joined)
        {
            form.AddWidget(joined, page, rect);
            return (joined.Name, form.Find(joined.Name)!.Widgets.Count - 1);
        }
        var spec = new FieldSpec(kind, named ?? NewName(form, kind), page, rect)
        {
            Caption = kind == FieldKind.PushButton ? Loc.T("Button") : null,
            Rotation = PageRotation(form, page),
        };
        return (form.AddField(spec).Name, 0);
    }

    /// <summary>Adds the fields the detector found; a name another field already holds, or sits under, gets a number.</summary>
    public static int AddFound(PdfForm form, IEnumerable<FieldProposal> found)
    {
        int added = 0;
        foreach (var proposal in found)
        {
            var spec = proposal.ToSpec();
            string stem = spec.Name.Replace('.', '_');
            string name = Taken(form, spec.Name) ? stem : spec.Name;
            for (int n = 2; Taken(form, name); n++) name = stem + "_" + n;
            form.AddField(spec with { Name = name, Rotation = PageRotation(form, spec.PageIndex) });
            added++;
        }
        return added;
    }

    // A widget is drawn along the page as the person sees it, so a turned page turns the widget the same way.
    private static int PageRotation(PdfForm form, int page) => (form.Document.Pages[page].Rotate % 360 + 360) % 360;

    private static bool Taken(PdfForm form, string name) =>
        form.Fields.Any(f => f.Name == name || f.Name.StartsWith(name + '.') || name.StartsWith(f.Name + '.'));

    /// <summary>Whether the file's permissions let the fields themselves change, which filling does not need.</summary>
    public static bool CanModify(PdfDocument document) =>
        document.Security is not { } security || security.OpenedAsOwner || security.Permissions.HasFlag(PdfPermissions.Modify);

    public static string CaptionOf(PdfForm form, FormField field) =>
        field.Widgets.Select(w => form.Document.Resolve(w.Dictionary["MK"]) as PdfDictionary).OfType<PdfDictionary>()
            .Select(mk => PdfText.Read(form.Document, mk, "CA")).FirstOrDefault(c => c is not null) ?? "";

    public static void SetCaption(PdfForm form, FormField field, string caption)
    {
        foreach (var widget in field.Widgets)
        {
            if (form.Document.Resolve(widget.Dictionary["MK"]) is not PdfDictionary mk) widget.Dictionary["MK"] = mk = new PdfDictionary();
            mk["CA"] = PdfText.ToObject(caption);
        }
        form.Regenerate([field]);
    }

    /// <summary>The address a link or a submit goes to: web addresses and mailto links as typed, a bare e-mail address with mailto: before it, anything else with https://. Null when it is not an address.</summary>
    public static string? AddressOf(string text)
    {
        string typed = text.Trim();
        if (typed.Length == 0 || typed.Contains(' ')) return null;
        if (!typed.Contains(':')) typed = (typed.Contains('@') && !typed.Contains('/') ? "mailto:" : "https://") + typed;
        // https://name@host reads as a web address with a user name, which is rarely what was meant.
        return Uri.TryCreate(typed, UriKind.Absolute, out var uri) && ((uri.Scheme is "http" or "https" && uri.Host.Length > 0 && uri.UserInfo.Length == 0) || uri.Scheme == "mailto") ? typed : null;
    }

    /// <summary>Whether two text colours (1, 3 or 4 numbers) are the same on screen.</summary>
    public static bool SameColour(double[] a, double[] b) => Rgb(a).Zip(Rgb(b), (x, y) => Math.Abs(x - y) < 0.02).All(same => same);

    private static double[] Rgb(double[] c) => c.Length switch
    {
        1 => [c[0], c[0], c[0]],
        4 => [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])],
        _ => c.Length == 3 ? c : [0, 0, 0],
    };

    public static IReadOnlyList<FieldOption> ParseOptions(string text) =>
    [
        .. text.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).Select(line =>
        {
            int equals = line.IndexOf('=');
            return equals > 0 ? new FieldOption(line[..equals].Trim(), line[(equals + 1)..].Trim()) : new FieldOption(line);
        }),
    ];

    public static string FormatOptions(IReadOnlyList<FieldOption> options) =>
        string.Join("\r\n", options.Select(o => o.Export == o.Display ? o.Export : $"{o.Export}={o.Display}"));

    public static Problem ProblemOf(Exception error) => error switch
    {
        PdfReadException { Problem: PdfReadProblem.Unsupported } => new(Loc.T("Form not supported"), FormText.DynamicXfa),
        PdfReadException => new(Loc.T("Form cannot be read"), Loc.T("Lazy PDF cannot change this form. Try an earlier copy of the file.")),
        ArgumentException => new(Loc.T("Field not changed"), Loc.T("Check the name and the size of the field, then try again.")),
        _ => new(Loc.T("Field not changed"), error.Message),
    };
}
