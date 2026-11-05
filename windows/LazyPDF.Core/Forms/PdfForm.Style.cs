namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    // Bit 3 of the submit flags (table 237): send the values as an HTML form, which any web server reads.
    private const int SubmitAsHtml = 4;

    private static string DaString(string font, double size, double[] color) =>
        $"/{font} {new PdfNumber(size).Text} Tf {string.Join(' ', color.Select(n => new PdfNumber(n).Text))} {(color.Length switch { 1 => "g", 4 => "k", _ => "rg" })}";

    /// <summary>
    /// Makes the button stand for <paramref name="export"/>: the name of its "on" appearance state, or its
    /// /Opt entry for a radio group that has them. Another button of the field may not already use it.
    /// </summary>
    public void SetExportValue(FormWidget widget, string export)
    {
        RequireFillable();
        var field = widget.Field;
        if (field.Kind is not (FieldKind.CheckBox or FieldKind.Radio)) throw new ArgumentException(FormText.NotAButton, nameof(widget));
        export = export.Trim();
        if (export.Length == 0 || export == "Off") throw new ArgumentException(FormText.BadExport, nameof(export));
        int index = field.Widgets.ToList().FindIndex(w => ReferenceEquals(w.Dictionary, widget.Dictionary));
        if (index < 0) throw new InvalidOperationException(FormText.NotAField);
        // A check box drawn in several places has one state, which all its widgets share.
        var same = field.Kind == FieldKind.CheckBox && widget.OnState is { } shared
            ? field.Widgets.Where(w => w.OnState == shared).ToList() : [widget];
        if (field.Widgets.Where(w => !same.Contains(w)).Any(w => w.Export == export || w.OnState == export)) throw new InvalidOperationException(FormText.ExportTaken(export));
        if (widget.Export == export) return;

        if (field.Kind == FieldKind.Radio && field.Options.Count > index)
        {
            field.Dictionary["Opt"] = OptionsObject([.. field.Options.Select((o, i) => i == index ? new FieldOption(export) : o)]);
        }
        else if (widget.OnState is { } old)
        {
            foreach (var w in same)
            {
                var d = w.Dictionary;
                foreach (string key in (ReadOnlySpan<string>)["N", "D"])
                {
                    if (_document.Dict(_document.Dict(d, "AP"), key) is { } states && states[old] is { } state)
                    {
                        states.Remove(old);
                        states[export] = state;
                    }
                }
                if (_document.Name(d, "AS") == old) d["AS"] = new PdfName(export);
            }
            foreach (string key in (ReadOnlySpan<string>)["V", "DV"])
            {
                if (_document.Resolve(field.Dictionary[key]) is PdfName name && name.Value == old) field.Dictionary[key] = new PdfName(export);
            }
        }
        else
        {
            new FormAppearance(_document).Apply(field, widget, null, "", onState: export);
            widget.Dictionary["AS"] = new PdfName("Off");
        }
        DropXfa();
        Refresh();
    }

    /// <summary>Sets the font of the field's text to a name in /DR /Font or one of the standard names (Helv, TiRo, Cour and their bold and italic forms) and draws it again.</summary>
    public void SetFont(FormField field, string font)
    {
        RequireFillable();
        bool known = DefaultAppearance.IsStandard(font) || _document.Dict(_document.Dict(AcroForm, "DR"), "Font")?.ContainsKey(font) == true;
        if (!known) throw new ArgumentException(FormText.UnknownFont(font), nameof(font));
        Restyle(field, font, null, null);
    }

    /// <summary>Sets the size of the field's text in points, 0 to fit the text to the field.</summary>
    public void SetFontSize(FormField field, double size)
    {
        RequireFillable();
        if (!(size is >= 0 and <= 200)) throw new ArgumentException(FormText.BadSize, nameof(size));
        Restyle(field, null, size, null);
    }

    /// <summary>Sets the colour of the field's text, or of the mark of a check box or radio button: 1, 3 or 4 numbers from 0 to 1.</summary>
    public void SetTextColor(FormField field, double[] color)
    {
        RequireFillable();
        if (color.Length is not (1 or 3 or 4) || color.Any(n => !(n is >= 0 and <= 1))) throw new ArgumentException(FormText.BadColor, nameof(color));
        Restyle(field, null, null, color);
    }

    /// <summary>How the field's text is set, with the form's defaults for what its /DA leaves out.</summary>
    public TextLook GetTextLook(FormField field)
    {
        var (font, size, color) = DefaultAppearance.Parse(field.DefaultAppearance);
        return new TextLook(font ?? "Helv", size ?? 0, color ?? [0]);
    }

    private void Restyle(FormField field, string? font, double? size, double[]? color)
    {
        var (oldFont, oldSize, oldColor) = DefaultAppearance.Parse(field.DefaultAppearance);
        field.Dictionary["DA"] = PdfText.ToObject(DaString(font ?? oldFont ?? "Helv", size ?? oldSize ?? 0, color ?? oldColor ?? [0]));
        // A widget with a /DA of its own would keep the old look.
        foreach (var widget in field.Widgets.Where(w => !ReferenceEquals(w.Dictionary, field.Dictionary))) widget.Dictionary.Remove("DA");
        Refresh();
        Regenerate([Current(field) ?? field]);
    }

    /// <summary>What the push button does: the action of its first widget.</summary>
    public ButtonAction GetButtonAction(FormField field)
    {
        var d = field.Widgets.FirstOrDefault()?.Dictionary;
        if (_document.Dict(d, "A") is not { } a) return new ButtonAction(ButtonActionKind.None);
        if (_document.Name(a, "S") == "Hide")
        {
            string? target = PdfText.Read(_document, a["T"]) ?? (_document.Resolve(a["T"]) as PdfName)?.Value;
            return new ButtonAction(_document.Bool(a, "H") == false ? ButtonActionKind.Show : ButtonActionKind.Hide, target);
        }
        return PdfActions.Read(_document, a) switch
        {
            UriAction uri => new ButtonAction(ButtonActionKind.OpenLink, uri.Uri),
            ResetFormAction { Fields.Count: 0 } => new ButtonAction(ButtonActionKind.Reset),
            SubmitFormAction submit => new ButtonAction(ButtonActionKind.Submit, submit.Url),
            _ => new ButtonAction(ButtonActionKind.Other),
        };
    }

    /// <summary>Gives every widget of the push button the action, or none. Show and Hide name a field of the form.</summary>
    public void SetButtonAction(FormField field, ButtonAction action)
    {
        RequireFillable();
        if (field.Kind != FieldKind.PushButton) throw new ArgumentException(FormText.NotAPushButton, nameof(field));
        string target = action.Target?.Trim() ?? "";
        PdfObject? written;
        switch (action.Kind)
        {
            case ButtonActionKind.None:
                written = null;
                break;
            case ButtonActionKind.OpenLink or ButtonActionKind.Submit:
                if (target.Length == 0) throw new ArgumentException(FormText.NoAddress, nameof(action));
                written = PdfActions.ToObject(_document, action.Kind == ButtonActionKind.OpenLink ? new UriAction(target) : new SubmitFormAction(target, SubmitAsHtml, []));
                break;
            case ButtonActionKind.Reset:
                written = PdfActions.ToObject(_document, new ResetFormAction(0, []));
                break;
            case ButtonActionKind.Show or ButtonActionKind.Hide:
                if (Find(target) is null) throw new InvalidOperationException(FormText.NoSuchField(target));
                written = new PdfDictionary
                {
                    ["Type"] = new PdfName("Action"),
                    ["S"] = new PdfName("Hide"),
                    ["T"] = PdfText.ToObject(target),
                    ["H"] = new PdfBoolean(action.Kind == ButtonActionKind.Hide),
                };
                break;
            default:
                throw new ArgumentException(FormText.OtherAction, nameof(action));
        }
        foreach (var widget in field.Widgets)
        {
            if (written is null) widget.Dictionary.Remove("A");
            else widget.Dictionary["A"] = written is PdfDictionary dictionary ? dictionary.Copy() : written;
        }
        DropXfa();
        Refresh();
    }
}
