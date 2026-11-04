namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    /// <summary>
    /// The field values as an FDF file (ISO 32000-1 12.7.7), with <see cref="PdfFdf.Write"/> or
    /// <see cref="PdfXfdf.Write"/> to turn it into bytes. Buttons, signatures and fields marked no-export
    /// are left out; a name two fields share is written once. A name with periods becomes nested fields.
    /// </summary>
    public FdfFile ExportFdf(string? fileName = null)
    {
        var fdf = new FdfFile { FileName = fileName };
        var root = new Node("");
        foreach (var field in Exported())
        {
            var node = root;
            foreach (string part in field.Name.Split('.')) node = node.Child(part);
            node.Value = FdfValue(field);
        }
        fdf.Fields.AddRange(root.Children.Select(c => c.ToField()));
        return fdf;
    }

    /// <summary>Fills the fields the FDF or XFDF file names. Values go through <see cref="SetValues"/>, so appearances are drawn and calculations run.</summary>
    public FormFillResult ImportFdf(FdfFile fdf)
    {
        var entries = new List<(string, string?, IReadOnlyList<string>?)>();
        foreach (var (name, value) in fdf.FlatFields())
        {
            switch (fdf.Resolve(value))
            {
                case PdfArray array:
                    entries.Add((name, null, [.. array.Items.Select(i => TextOf(fdf.Resolve(i))).OfType<string>()]));
                    break;
                case { } one when TextOf(one) is { } text:
                    entries.Add((name, text, null));
                    break;
            }
        }
        return Fill(entries);
    }

    /// <summary>
    /// The values as a two-line CSV text: the field names, then what they hold. Check boxes and radio
    /// groups give their export value or Off, a list with several choices joins them with "; ".
    /// </summary>
    public string ExportCsv()
    {
        var fields = Exported().ToList();
        return FormCsv.Write([fields.Select(f => f.Name), fields.Select(CsvValue)]);
    }

    private IEnumerable<FormField> Exported() => _fields
        .Where(f => f.Kind is not (FieldKind.PushButton or FieldKind.Signature) && !f.Has(FieldFlags.NoExport))
        .GroupBy(f => f.Name).Select(g => g.First());

    private PdfObject FdfValue(FormField field)
    {
        switch (field.Kind)
        {
            case FieldKind.CheckBox or FieldKind.Radio:
                if (field.Value is null or "Off") return new PdfName("Off");
                return new PdfName(field.Widgets.FirstOrDefault(w => w.Export == field.Value)?.OnState ?? field.Value);
            case FieldKind.ListBox when field.Has(FieldFlags.MultiSelect):
                return new PdfArray([.. field.Selected.Select(s => (PdfObject)PdfText.ToObject(s))]);
            default:
                return PdfText.ToObject(field.Kind is FieldKind.ComboBox or FieldKind.ListBox ? field.Selected.FirstOrDefault() ?? "" : field.Value ?? "");
        }
    }

    private static string CsvValue(FormField field) => field.Kind switch
    {
        FieldKind.ListBox => string.Join("; ", field.Selected),
        _ => field.Value ?? "",
    };

    private static string? TextOf(PdfObject? value) => value switch
    {
        PdfString s => PdfText.Decode(s.Bytes),
        PdfName n => n.Value,
        PdfNumber n => n.Text,
        _ => null,
    };

    private sealed class Node(string name)
    {
        public List<Node> Children { get; } = [];
        public PdfObject? Value { get; set; }

        public Node Child(string part)
        {
            var found = Children.Find(c => c.Name == part);
            if (found is null) Children.Add(found = new Node(part));
            return found;
        }

        public string Name { get; } = name;

        public FdfField ToField() => new(Name, Value, [.. Children.Select(c => c.ToField())]);
    }
}
