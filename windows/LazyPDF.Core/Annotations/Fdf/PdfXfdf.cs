using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace LazyPDF.Core;

/// <summary>
/// XFDF (ISO 19444-1): the XML form of the data an FDF file holds. Appearance streams, attachment data
/// and the image of an image stamp have no place in what is read or written here; an imported
/// annotation gets its appearance drawn from its attributes.
/// </summary>
public static class PdfXfdf
{
    private static readonly XNamespace Ns = "http://ns.adobe.com/xfdf/";
    private const int MaxItems = 200_000;

    private static readonly string[] Subtypes =
    [
        "Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly",
        "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "FileAttachment", "Redact",
    ];

    private static readonly string[] FlagNames =
        ["invisible", "hidden", "print", "nozoom", "norotate", "noview", "readonly", "locked", "togglenoview", "lockedcontents"];

    /// <summary>Reads XFDF. Throws <see cref="PdfReadException"/> (Damaged) for XML that is not well-formed, has a DTD, or has no xfdf element.</summary>
    public static FdfFile Read(byte[] data) => Load(() => XmlReader.Create(new MemoryStream(data), Settings()));

    public static FdfFile Read(string xml) => Load(() => XmlReader.Create(new StringReader(xml), Settings()));

    private static FdfFile Load(Func<XmlReader> open)
    {
        try
        {
            using var reader = open();
            return Read(XDocument.Load(reader));
        }
        catch (XmlException e)
        {
            throw PdfReadException.Damaged("The XFDF is not well-formed: " + e.Message);
        }
    }

    private static XmlReaderSettings Settings() =>
        new() { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 64L << 20 };

    private static FdfFile Read(XDocument document)
    {
        var root = document.Root;
        if (root is null || root.Name != Ns + "xfdf") throw PdfReadException.Damaged("There is no xfdf element in the file.");
        var fdf = new FdfFile { FileName = root.Element(Ns + "f")?.Attribute("href")?.Value };
        int count = 0;
        if (root.Element(Ns + "fields") is { } fields) fdf.Fields.AddRange(ReadFields(fields, 0, ref count));
        if (root.Element(Ns + "annots") is { } annots)
        {
            foreach (var element in annots.Elements().Take(PdfAnnotations.MaxAnnotations))
            {
                if (Subtypes.FirstOrDefault(s => s.Equals(element.Name.LocalName, StringComparison.OrdinalIgnoreCase)) is not { } subtype) continue;
                string? given = element.Attribute("page")?.Value;
                int page = int.TryParse(given, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int p) ? p : given is null ? 0 : -1;
                fdf.Annotations.Add(new FdfAnnotation(page, ReadAnnotation(element, subtype)));
            }
        }
        return fdf;
    }

    private static List<FdfField> ReadFields(XElement parent, int depth, ref int count)
    {
        var fields = new List<FdfField>();
        foreach (var element in parent.Elements(Ns + "field"))
        {
            if (count++ >= MaxItems) break;
            var kids = depth < 32 ? ReadFields(element, depth + 1, ref count) : [];
            var values = element.Elements(Ns + "value").Select(v => PdfText.ToObject(v.Value)).ToList();
            PdfObject? value = values.Count switch { 0 => null, 1 => values[0], _ => new PdfArray([.. values]) };
            fields.Add(new FdfField(element.Attribute("name")?.Value ?? "", value, kids));
        }
        return fields;
    }

    private static PdfDictionary ReadAnnotation(XElement e, string subtype)
    {
        var d = new PdfDictionary { ["Type"] = new PdfName("Annot"), ["Subtype"] = new PdfName(subtype) };
        string? A(string name) => e.Attribute(name)?.Value;
        void Text(string attribute, string key) { if (A(attribute) is { } v) d[key] = PdfText.ToObject(v); }
        void Name(string attribute, string key) { if (A(attribute) is { Length: > 0 } v) d[key] = new PdfName(v); }
        void Number(string attribute, string key) { if (Parse(A(attribute)) is { } n) d[key] = new PdfNumber(n); }

        Text("name", "NM"); Text("title", "T"); Text("subject", "Subj"); Text("date", "M"); Text("creationdate", "CreationDate");
        Text("state", "State"); Text("statemodel", "StateModel"); Text("overlaytext", "OverlayText");
        Name("icon", "Name"); Name("intent", "IT");
        if (A("replyType") is { Length: > 0 } replyType) d["RT"] = new PdfName(replyType == "group" ? "Group" : replyType == "reply" ? "R" : replyType);
        if (A("symbol") is { Length: > 0 } symbol) d["Sy"] = new PdfName(symbol == "paragraph" ? "P" : symbol == "none" ? "None" : symbol);
        Number("opacity", "CA");
        if (A("justification") is { } justification)
        {
            int? q = justification switch { "left" => 0, "centered" => 1, "right" => 2, _ => (int?)Parse(justification) };
            if (q is { } alignment) d["Q"] = new PdfNumber(alignment);
        }
        if (A("open") is { } open) d["Open"] = new PdfBoolean(open.Equals("yes", StringComparison.OrdinalIgnoreCase) || open == "true");
        if (A("inreplyto") is { } reply) d["IRT"] = PdfText.ToObject(reply);

        if (Numbers(A("rect")) is { Length: 4 } rect) d["Rect"] = Array(rect);
        if (HexColor(A("color")) is { } color) d["C"] = Array(color);
        if (HexColor(A("interior-color")) is { } interior) d["IC"] = Array(interior);
        if (Numbers(A("coords")) is { Length: > 0 } coords) d["QuadPoints"] = Array(coords);
        if (Numbers(A("fringe")) is { Length: 4 } fringe) d["RD"] = Array(fringe);
        if (Numbers(A("callout")) is { Length: >= 4 } callout) d["CL"] = Array(callout);
        if (A("flags") is { } flags) d["F"] = new PdfNumber(ParseFlags(flags));
        if (Numbers(A("start")) is { Length: 2 } from && Numbers(A("end")) is { Length: 2 } to) d["L"] = Array([.. from, .. to]);
        if (A("head") is not null || A("tail") is not null)
        {
            d["LE"] = new PdfArray([new PdfName(A("head") ?? "None"), new PdfName(A("tail") ?? "None")]);
        }

        string? style = A("style");
        if (Parse(A("width")) is not null || style is "dash" or "dashed" or "beveled" or "inset" or "underline")
        {
            var bs = new PdfDictionary { ["Type"] = new PdfName("Border"), ["W"] = new PdfNumber(Parse(A("width")) ?? 1) };
            bs["S"] = new PdfName(style switch { "dash" or "dashed" => "D", "beveled" => "B", "inset" => "I", "underline" => "U", _ => "S" });
            if (Numbers(A("dashes")) is { Length: > 0 } dashes) bs["D"] = Array(dashes);
            d["BS"] = bs;
        }
        if (style == "cloudy")
        {
            d["BE"] = new PdfDictionary { ["S"] = new PdfName("C"), ["I"] = new PdfNumber(Parse(A("intensity")) ?? 1) };
        }

        foreach (var child in e.Elements())
        {
            switch (child.Name.LocalName)
            {
                case "contents": d["Contents"] = PdfText.ToObject(child.Value); break;
                case "contents-richtext": d["RC"] = PdfText.ToObject(string.Concat(child.Nodes().Select(n => n.ToString()))); break;
                case "defaultappearance": d["DA"] = PdfText.ToObject(child.Value); break;
                case "defaultstyle": d["DS"] = PdfText.ToObject(child.Value); break;
                case "vertices": d["Vertices"] = Array(Numbers(child.Value)); break;
                case "inklist":
                    d["InkList"] = new PdfArray([.. child.Elements().Where(g => g.Name.LocalName == "gesture").Select(g => (PdfObject)Array(Numbers(g.Value)))]);
                    break;
                case "popup":
                {
                    var popup = new PdfDictionary();
                    if (Numbers(child.Attribute("rect")?.Value) is { Length: 4 } r) popup["Rect"] = Array(r);
                    if (child.Attribute("flags")?.Value is { } f) popup["F"] = new PdfNumber(ParseFlags(f));
                    if (child.Attribute("open")?.Value is { } o) popup["Open"] = new PdfBoolean(o.Equals("yes", StringComparison.OrdinalIgnoreCase));
                    d["Popup"] = popup;
                    break;
                }
            }
        }
        return d;
    }

    public static byte[] Write(FdfFile fdf)
    {
        fdf.Link();
        var root = new XElement(Ns + "xfdf", new XAttribute(XNamespace.Xml + "space", "preserve"));
        if (fdf.FileName is { } file) root.Add(new XElement(Ns + "f", new XAttribute("href", Clean(file))));
        if (fdf.Fields.Count > 0) root.Add(new XElement(Ns + "fields", fdf.Fields.Select(WriteField)));
        var annots = new XElement(Ns + "annots");
        // A reply names its parent, so the parent needs a name before any element is written.
        foreach (var annotation in fdf.Annotations)
        {
            if (fdf.Resolve(annotation.Dictionary["IRT"]) is PdfDictionary parent) parent["NM"] ??= PdfText.ToObject(Guid.NewGuid().ToString());
        }
        foreach (var annotation in fdf.Annotations)
        {
            if ((annotation.Dictionary["Subtype"] as PdfName)?.Value is { } subtype and not "Popup") annots.Add(WriteAnnotation(fdf, annotation, subtype));
        }
        if (annots.HasElements) root.Add(annots);

        using var output = new MemoryStream();
        using (var writer = XmlWriter.Create(output, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = true }))
        {
            new XDocument(new XDeclaration("1.0", "UTF-8", null), root).Save(writer);
        }
        return output.ToArray();
    }

    private static XElement WriteField(FdfField field)
    {
        var element = new XElement(Ns + "field", new XAttribute("name", Clean(field.Name)));
        var values = field.Value switch
        {
            PdfArray array => array.Items.Select(Text),
            null => [],
            var single => [Text(single)],
        };
        foreach (string value in values) element.Add(new XElement(Ns + "value", Clean(value)));
        foreach (var kid in field.Kids) element.Add(WriteField(kid));
        return element;
    }

    private static string Text(PdfObject value) => value switch
    {
        PdfString s => PdfText.Decode(s.Bytes),
        PdfName n => n.Value,
        PdfNumber n => n.Text,
        PdfBoolean b => b.Value ? "true" : "false",
        _ => "",
    };

    private static XElement WriteAnnotation(FdfFile fdf, FdfAnnotation annotation, string subtype)
    {
        var d = annotation.Dictionary;
        var e = new XElement(Ns + subtype.ToLowerInvariant(), new XAttribute("page", annotation.PageIndex));
        PdfObject? V(string key) => fdf.Resolve(d[key]);
        void Put(string attribute, string? value)
        {
            if (value is not null) e.SetAttributeValue(attribute, Clean(value));
        }
        string? TextOf(string key) => V(key) is PdfString s ? PdfText.Decode(s.Bytes) : null;
        string? NameOf(string key) => (V(key) as PdfName)?.Value;
        string? NumberOf(string key) => (V(key) as PdfNumber)?.Text;
        string? List(string key) => V(key) is PdfArray a ? string.Join(',', a.Items.Select(i => (fdf.Resolve(i) as PdfNumber)?.Text ?? "0")) : null;

        Put("rect", List("Rect"));
        Put("name", TextOf("NM")); Put("title", TextOf("T")); Put("subject", TextOf("Subj"));
        Put("date", TextOf("M")); Put("creationdate", TextOf("CreationDate"));
        Put("opacity", NumberOf("CA"));
        Put("justification", (V("Q") as PdfNumber)?.Integer switch { 0 => "left", 1 => "centered", 2 => "right", _ => null });
        Put("icon", NameOf("Name")); Put("intent", NameOf("IT"));
        Put("replyType", NameOf("RT") switch { "R" => "reply", "Group" => "group", var other => other });
        Put("symbol", NameOf("Sy") switch { "P" => "paragraph", "None" => "none", var other => other });
        Put("state", TextOf("State")); Put("statemodel", TextOf("StateModel")); Put("overlaytext", TextOf("OverlayText"));
        Put("coords", List("QuadPoints")); Put("fringe", List("RD")); Put("callout", List("CL"));
        if (V("Open") is PdfBoolean open) Put("open", open.Value ? "yes" : "no");
        if (V("F") is PdfNumber flags && flags.Integer is { } f) Put("flags", string.Join(',', FlagNames.Where((_, i) => (f >> i & 1) != 0)));
        Put("color", HexOf(V("C"))); Put("interior-color", HexOf(V("IC")));
        if (V("IRT") is PdfDictionary parent)
        {
            parent["NM"] ??= PdfText.ToObject(Guid.NewGuid().ToString());
            Put("inreplyto", PdfText.Decode(((PdfString)parent["NM"]!).Bytes));
        }
        if (V("L") is PdfArray { Items.Count: 4 } line)
        {
            var n = line.Items.Select(i => (fdf.Resolve(i) as PdfNumber)?.Text ?? "0").ToArray();
            Put("start", $"{n[0]},{n[1]}");
            Put("end", $"{n[2]},{n[3]}");
        }
        if (V("LE") is PdfArray { Items.Count: > 0 } ends)
        {
            Put("head", (fdf.Resolve(ends.Items[0]) as PdfName)?.Value);
            if (ends.Items.Count > 1) Put("tail", (fdf.Resolve(ends.Items[1]) as PdfName)?.Value);
        }
        else if (V("LE") is PdfName single) Put("head", single.Value);
        if (fdf.Resolve(d["BS"]) is PdfDictionary bs)
        {
            Put("width", (fdf.Resolve(bs["W"]) as PdfNumber)?.Text);
            Put("style", (fdf.Resolve(bs["S"]) as PdfName)?.Value switch { "D" => "dash", "B" => "beveled", "I" => "inset", "U" => "underline", _ => "solid" });
            if (fdf.Resolve(bs["D"]) is PdfArray dash) Put("dashes", string.Join(',', dash.Items.Select(i => (fdf.Resolve(i) as PdfNumber)?.Text ?? "0")));
        }
        if (fdf.Resolve(d["BE"]) is PdfDictionary be && (fdf.Resolve(be["S"]) as PdfName)?.Value == "C")
        {
            Put("style", "cloudy");
            Put("intensity", (fdf.Resolve(be["I"]) as PdfNumber)?.Text ?? "1");
        }

        if (TextOf("Contents") is { } contents) e.Add(new XElement(Ns + "contents", Clean(contents)));
        if (TextOf("RC") is { } rich && TryParseFragment(rich) is { } nodes) e.Add(new XElement(Ns + "contents-richtext", nodes));
        if (TextOf("DA") is { } da) e.Add(new XElement(Ns + "defaultappearance", Clean(da)));
        if (TextOf("DS") is { } ds) e.Add(new XElement(Ns + "defaultstyle", Clean(ds)));
        if (V("Vertices") is PdfArray vertices) e.Add(new XElement(Ns + "vertices", Pairs(fdf, vertices)));
        if (V("InkList") is PdfArray ink)
        {
            e.Add(new XElement(Ns + "inklist", ink.Items.Select(i => fdf.Resolve(i)).OfType<PdfArray>().Select(g => new XElement(Ns + "gesture", Pairs(fdf, g)))));
        }
        if (V("Popup") is PdfDictionary popup)
        {
            var element = new XElement(Ns + "popup", new XAttribute("page", annotation.PageIndex));
            if (fdf.Resolve(popup["Rect"]) is PdfArray r) element.SetAttributeValue("rect", string.Join(',', r.Items.Select(i => (fdf.Resolve(i) as PdfNumber)?.Text ?? "0")));
            if (fdf.Resolve(popup["Open"]) is PdfBoolean o) element.SetAttributeValue("open", o.Value ? "yes" : "no");
            e.Add(element);
        }
        return e;
    }

    // The /RC string parsed as XML so that it nests as markup, not as escaped text.
    private static IEnumerable<XNode>? TryParseFragment(string xhtml)
    {
        try
        {
            return new[] { XElement.Parse(xhtml) };
        }
        catch (XmlException)
        {
            return null;
        }
    }

    private static string Pairs(FdfFile fdf, PdfArray array)
    {
        var numbers = array.Items.Select(i => (fdf.Resolve(i) as PdfNumber)?.Text ?? "0").ToList();
        var pairs = new List<string>();
        for (int i = 0; i + 1 < numbers.Count; i += 2) pairs.Add(numbers[i] + "," + numbers[i + 1]);
        return string.Join(';', pairs);
    }

    private static string? HexOf(PdfObject? color)
    {
        if (color is not PdfArray array || array.Items.Count is not (1 or 3 or 4)) return null;
        var n = array.Items.Select(i => (i as PdfNumber)?.Value ?? 0).ToArray();
        double r, g, b;
        switch (n.Length)
        {
            case 1: (r, g, b) = (n[0], n[0], n[0]); break;
            case 3: (r, g, b) = (n[0], n[1], n[2]); break;
            default: (r, g, b) = ((1 - n[0]) * (1 - n[3]), (1 - n[1]) * (1 - n[3]), (1 - n[2]) * (1 - n[3])); break;
        }
        static string Byte(double v) => ((int)Math.Round(Math.Clamp(v, 0, 1) * 255)).ToString("X2", CultureInfo.InvariantCulture);
        return "#" + Byte(r) + Byte(g) + Byte(b);
    }

    private static double[]? HexColor(string? text)
    {
        if (text is not { Length: 7 } || text[0] != '#' || !int.TryParse(text[1..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int rgb)) return null;
        return [(rgb >> 16 & 255) / 255.0, (rgb >> 8 & 255) / 255.0, (rgb & 255) / 255.0];
    }

    private static long ParseFlags(string text)
    {
        long flags = 0;
        foreach (string name in text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            int bit = System.Array.IndexOf(FlagNames, name.ToLowerInvariant());
            if (bit >= 0) flags |= 1L << bit;
        }
        return flags;
    }

    private static double? Parse(string? text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) && double.IsFinite(v) ? v : null;

    // Numbers separated by commas, semicolons or spaces.
    private static double[] Numbers(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var list = new List<double>();
        foreach (string part in text.Split([',', ';', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (list.Count >= 1_000_000) break;
            list.Add(Parse(part) ?? 0);
        }
        return [.. list];
    }

    private static PdfArray Array(IEnumerable<double> numbers) => new([.. numbers.Select(n => (PdfObject)new PdfNumber(n))]);

    private static string Clean(string text) => new([.. text.Where(c => XmlConvert.IsXmlChar(c) || char.IsSurrogate(c))]);
}
