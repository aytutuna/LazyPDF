using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

public enum AlignKind { Left, Centre, Right, Top, Middle, Bottom, SpaceAcross, SpaceDown }

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

    /// <summary>Every widget on a page with its box, in the order of the fields; the ordinal tells apart fields that share a name.</summary>
    public static List<(string Name, int Index, int Ordinal, Rect Box)> Widgets(PdfForm form, int page, Func<FormWidget, Rect> boxOf)
    {
        var found = new List<(string, int, int, Rect)>();
        var seen = new Dictionary<string, int>();
        foreach (var field in form.Fields)
        {
            int ordinal = seen.GetValueOrDefault(field.Name);
            seen[field.Name] = ordinal + 1;
            for (int i = 0; i < field.Widgets.Count; i++)
            {
                if (field.Widgets[i].PageIndex == page) found.Add((field.Name, i, ordinal, boxOf(field.Widgets[i])));
            }
        }
        return found;
    }

    /// <summary>Gives each widget its rectangle.</summary>
    public static void ResizeAll(PdfForm form, IEnumerable<(string Name, int Index, int Ordinal, PdfRect Rect)> moves)
    {
        foreach (var (name, index, ordinal, rect) in moves) form.Resize(WidgetOf(form, name, index, ordinal), rect);
    }

    /// <summary>The boxes after aligning to the first one, or after spacing the gaps evenly between the two outermost; sizes stay.</summary>
    public static Rect[] Align(IReadOnlyList<Rect> boxes, AlignKind kind)
    {
        var result = boxes.ToArray();
        if (boxes.Count == 0) return result;
        var first = boxes[0];
        if (kind is AlignKind.SpaceAcross or AlignKind.SpaceDown)
        {
            bool across = kind == AlignKind.SpaceAcross;
            var order = Enumerable.Range(0, boxes.Count).OrderBy(i => across ? boxes[i].X : boxes[i].Y).ToList();
            double start = across ? boxes[order[0]].X : boxes[order[0]].Y;
            double end = across ? boxes[order[^1]].Right : boxes[order[^1]].Bottom;
            double gap = (end - start - order.Sum(i => across ? boxes[i].Width : boxes[i].Height)) / Math.Max(1, boxes.Count - 1);
            double at = start;
            foreach (int i in order)
            {
                if (across) result[i].X = at; else result[i].Y = at;
                at += (across ? boxes[i].Width : boxes[i].Height) + gap;
            }
            return result;
        }
        for (int i = 0; i < result.Length; i++)
        {
            switch (kind)
            {
                case AlignKind.Left: result[i].X = first.X; break;
                case AlignKind.Centre: result[i].X = first.X + (first.Width - result[i].Width) / 2; break;
                case AlignKind.Right: result[i].X = first.Right - result[i].Width; break;
                case AlignKind.Top: result[i].Y = first.Y; break;
                case AlignKind.Middle: result[i].Y = first.Y + (first.Height - result[i].Height) / 2; break;
                default: result[i].Y = first.Bottom - result[i].Height; break;
            }
        }
        return result;
    }

    /// <summary>Takes the widgets out. Each removal reads the form again, so the last widgets go first and a radio group loses its buttons from the end.</summary>
    public static void RemoveAll(PdfForm form, IEnumerable<(string Name, int Index, int Ordinal)> picked)
    {
        foreach (var (name, index, ordinal) in picked.OrderByDescending(p => p.Ordinal).ThenByDescending(p => p.Index))
            form.Remove(WidgetOf(form, name, index, ordinal));
    }

    private static FormWidget WidgetOf(PdfForm form, string name, int index, int ordinal) =>
        form.FindAll(name).ElementAtOrDefault(ordinal)?.Widgets.ElementAtOrDefault(index) ?? throw new InvalidOperationException(FormText.NotAField);

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

    /// <summary>What it takes to make the widget again: the field's settings and the look the widget itself carries.</summary>
    public static FieldSpec CopySpec(PdfForm form, FormField field, FormWidget widget)
    {
        var document = form.Document;
        var look = form.GetTextLook(field);
        var mk = document.Dict(widget.Dictionary, "MK");
        var bs = document.Dict(widget.Dictionary, "BS");
        double[]? Colour(string key) => document.Array(mk, key) is { Items.Count: 1 or 3 or 4 } array
            ? [.. array.Items.Select(i => (document.Resolve(i) as PdfNumber)?.Value ?? 0)] : null;
        return new FieldSpec(field.Kind, field.Name, widget.PageIndex, widget.Rect)
        {
            DefaultValue = field.DefaultValue,
            Options = field.Options,
            Flags = field.Flags,
            MaxLength = field.MaxLength,
            Tooltip = field.Tooltip,
            Font = look.Font,
            FontSize = look.Size,
            TextColor = look.Color,
            BorderColor = Colour("BC"),
            Background = Colour("BG"),
            BorderWidth = document.Number(bs, "W") ?? 1,
            BorderStyle = document.Name(bs, "S") switch { "D" => BorderStyle.Dashed, "B" => BorderStyle.Beveled, "I" => BorderStyle.Inset, "U" => BorderStyle.Underline, _ => BorderStyle.Solid },
            Alignment = field.Alignment,
            Caption = CaptionOf(form, field) is { Length: > 0 } caption ? caption : null,
            ExportValue = field.Kind is FieldKind.CheckBox or FieldKind.Radio ? widget.Export : null,
        };
    }

    /// <summary>
    /// Adds the copies 12 points right and down for each step, kept on the page. They go on their own page when
    /// <paramref name="ownPage"/> is set and the file has it, else on <paramref name="view"/>. A radio button joins
    /// the group of its name. Returns the name and widget index of each.
    /// </summary>
    public static List<(string Name, int Widget)> Paste(PdfForm form, IEnumerable<FieldSpec> specs, int view, bool ownPage, int step)
    {
        var added = new List<(string, int)>();
        foreach (var spec in specs)
        {
            int page = ownPage && spec.PageIndex < form.Document.Pages.Count ? spec.PageIndex : view;
            var crop = form.Document.Pages[page].CropBox;
            var r = spec.Rect;
            double left = Math.Clamp(r.Left + 12 * step, crop.Left, Math.Max(crop.Left, crop.Right - (r.Right - r.Left)));
            double bottom = Math.Clamp(r.Bottom - 12 * step, crop.Bottom, Math.Max(crop.Bottom, crop.Top - (r.Top - r.Bottom)));
            var rect = new PdfRect(left, bottom, left + (r.Right - r.Left), bottom + (r.Top - r.Bottom));
            if (spec.Kind == FieldKind.Radio && form.Find(spec.Name) is { Kind: FieldKind.Radio } group)
            {
                form.AddWidget(group, page, rect);
                added.Add((group.Name, form.Find(group.Name)!.Widgets.Count - 1));
                continue;
            }
            string stem = spec.Name.Replace('.', '_');
            string name = Taken(form, spec.Name) ? stem : spec.Name;
            for (int n = 2; Taken(form, name); n++) name = stem + "_" + n;
            added.Add((form.AddField(spec with { Name = name, PageIndex = page, Rect = rect, Rotation = PageRotation(form, page) }).Name, 0));
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
