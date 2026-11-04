namespace LazyPDF.Core;

// The form side of signing: the field that holds the signature, its widget, the signature dictionary
// and the entries that make a file certified or its fields locked.
internal static class SignatureField
{
    private const int WidgetFlags = 4 | 128; // Print, Locked

    /// <summary>Where the signature goes, found or made. Nothing is changed in the document until <see cref="Attach"/>.</summary>
    public sealed record Target(PdfDictionary Field, PdfReference? FieldReference, PdfDictionary Widget, PdfRect Rect, PdfPage Page, bool IsNew, bool Placed, string Name);

    public static Target Resolve(PdfDocument document, SignJob job)
    {
        var request = job.Request;
        var form = PdfForm.Read(document);
        if (request.FieldName is { } wanted && form.Find(wanted) is { } existing)
        {
            if (existing.Kind != FieldKind.Signature || existing.IsSigned) throw new InvalidOperationException(SignatureText.FieldTaken);
            SeedValues.Apply(document, existing.Dictionary, job);
            if (job.Lock is null && document.Dict(existing.Dictionary, "Lock") is { } lockDictionary) job.Lock = ReadLock(document, lockDictionary);
            var widget = existing.Widgets.FirstOrDefault();
            if (widget is { PageIndex: >= 0 })
            {
                return new Target(existing.Dictionary, existing.Reference, widget.Dictionary, widget.Rect, document.Pages[widget.PageIndex], false, true, existing.Name);
            }
            // A field nobody placed gets a widget when it is signed.
            return new Target(existing.Dictionary, existing.Reference, existing.Dictionary, request.Rect ?? default, Page(document, request.PageIndex), false, false, existing.Name);
        }

        string name = request.FieldName ?? Unique(form, "Signature");
        var field = new PdfDictionary();
        return new Target(field, null, field, request.Rect ?? default, Page(document, request.PageIndex), true, false, name);
    }

    private static PdfPage Page(PdfDocument document, int index) =>
        index >= 0 && index < document.Pages.Count ? document.Pages[index] : throw new ArgumentException(SignatureText.NoPage);

    public static string Unique(PdfForm form, string prefix)
    {
        for (int n = 1; ; n++)
        {
            string name = $"{prefix}{n}";
            if (form.Find(name) is null) return name;
        }
    }

    /// <summary>Hooks the signature into the file: the field's value, its widget and appearance, the form and the page.</summary>
    public static void Attach(PdfDocument document, Target target, PdfReference signature, PdfReference? appearance)
    {
        var field = target.Field;
        var widget = target.Widget;
        bool placed = target.Placed;
        if (target.IsNew)
        {
            field["FT"] = new PdfName("Sig");
            field["T"] = PdfText.ToObject(target.Name);
        }
        field["V"] = signature;
        if (!placed)
        {
            widget["Type"] = new PdfName("Annot");
            widget["Subtype"] = new PdfName("Widget");
            widget["Rect"] = target.Rect.ToArray();
            widget["F"] = new PdfNumber(WidgetFlags);
            widget["P"] = target.Page.Reference;
        }
        if (appearance is not null)
        {
            widget["AP"] = new PdfDictionary { ["N"] = appearance };
        }

        PdfReference reference = target.FieldReference ?? document.Add(field);
        if (!placed)
        {
            if (document.Array(target.Page.Dictionary, "Annots") is { } annots) annots.Items.Add(reference);
            else target.Page.Dictionary["Annots"] = new PdfArray([reference]);
        }
        if (target.IsNew || target.FieldReference is null) AddToForm(document, reference);
        else EnsureFlags(document);
    }

    private static void AddToForm(PdfDocument document, PdfReference field)
    {
        var form = document.Dict(document.Catalog, "AcroForm");
        if (form is null)
        {
            form = new PdfDictionary();
            document.Catalog["AcroForm"] = form;
        }
        if (document.Array(form, "Fields") is { } fields) fields.Items.Add(field);
        else form["Fields"] = new PdfArray([field]);
        EnsureFlags(document);
    }

    // SignaturesExist and AppendOnly: a viewer must save this file by incremental update.
    private static void EnsureFlags(PdfDocument document)
    {
        var form = document.Dict(document.Catalog, "AcroForm");
        if (form is null) return;
        form["SigFlags"] = new PdfNumber((document.Integer(form, "SigFlags") ?? 0) | 3);
    }

    public static PdfDictionary Dictionary(PdfDocument document, SignJob job, PdfString contents, string subFilter)
    {
        var request = job.Request;
        var sig = new PdfDictionary
        {
            ["Type"] = new PdfName("Sig"),
            ["Filter"] = new PdfName("Adobe.PPKLite"),
            ["SubFilter"] = new PdfName(subFilter),
            ["ByteRange"] = SignedUpdate.ByteRangePlaceholder(),
            ["Contents"] = contents,
            ["M"] = new PdfString(System.Text.Encoding.ASCII.GetBytes(PdfDate.Format(request.Time)), isHex: false),
            ["Name"] = PdfText.ToObject(job.Name),
        };
        if (job.Reason is { Length: > 0 } reason) sig["Reason"] = PdfText.ToObject(reason);
        if (request.Location is { Length: > 0 } location) sig["Location"] = PdfText.ToObject(location);
        if (request.ContactInfo is { Length: > 0 } contact) sig["ContactInfo"] = PdfText.ToObject(contact);

        var references = new List<PdfObject>();
        if (job.Certify != CertificationLevel.None)
        {
            var parameters = new PdfDictionary
            {
                ["Type"] = new PdfName("TransformParams"),
                ["P"] = new PdfNumber((long)job.Certify),
                ["V"] = new PdfName("1.2"),
            };
            references.Add(Reference("DocMDP", parameters, document));
        }
        if (job.Lock is { } fieldLock)
        {
            var parameters = new PdfDictionary
            {
                ["Type"] = new PdfName("TransformParams"),
                ["Action"] = new PdfName(fieldLock.Action.ToString()),
                ["V"] = new PdfName("1.2"),
            };
            if (fieldLock.Action != FieldLockAction.All) parameters["Fields"] = new PdfArray([.. fieldLock.Fields.Select(PdfText.ToObject)]);
            references.Add(Reference("FieldMDP", parameters, document));
        }
        if (references.Count > 0) sig["Reference"] = new PdfArray(references);
        return sig;
    }

    private static PdfDictionary Reference(string method, PdfDictionary parameters, PdfDocument document) => new()
    {
        ["Type"] = new PdfName("SigRef"),
        ["TransformMethod"] = new PdfName(method),
        ["TransformParams"] = parameters,
        ["Data"] = document.Trailer["Root"]!,
    };

    /// <summary>The catalog's /Perms /DocMDP, which is what makes a signature a certification.</summary>
    public static void Certify(PdfDocument document, PdfReference signature)
    {
        var perms = document.Dict(document.Catalog, "Perms");
        if (perms is null)
        {
            perms = new PdfDictionary();
            document.Catalog["Perms"] = perms;
        }
        perms["DocMDP"] = signature;
    }

    /// <summary>A field's /Lock dictionary; the lock a signature of the field applies.</summary>
    public static void WriteLock(PdfDictionary field, FieldLock fieldLock)
    {
        var dictionary = new PdfDictionary { ["Type"] = new PdfName("SigFieldLock"), ["Action"] = new PdfName(fieldLock.Action.ToString()) };
        if (fieldLock.Action != FieldLockAction.All) dictionary["Fields"] = new PdfArray([.. fieldLock.Fields.Select(PdfText.ToObject)]);
        field["Lock"] = dictionary;
    }

    public static FieldLock? ReadLock(PdfDocument document, PdfDictionary dictionary)
    {
        var action = document.Name(dictionary, "Action") switch
        {
            "All" => FieldLockAction.All,
            "Include" => FieldLockAction.Include,
            "Exclude" => FieldLockAction.Exclude,
            _ => (FieldLockAction?)null,
        };
        if (action is null) return null;
        var fields = document.Array(dictionary, "Fields")?.Items.Select(i => PdfText.Read(document, i)).OfType<string>().ToList() ?? [];
        return new FieldLock(action.Value, fields);
    }
}
