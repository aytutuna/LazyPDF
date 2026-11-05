using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Forms/FormsGolden.swift. One line of input is "<op> <words>" (the format is at the top of
// forms-input.txt): script parsing, the AF format, check and calculate functions, number and CSV reading, a form filled,
// reset, built, restyled, flattened and exported, and the blanks found on a page. Streams are shown decoded, because the
// deflate of the two sides is not the same one. Dates without a year are left out of the input: they would read the clock.
internal static class FormsGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            int space = line.IndexOf(' ');
            string op = space < 0 ? line : line[..space];
            string rest = space < 0 ? "" : line[(space + 1)..];
            output.Append("> ").Append(line).Append('\n');
            foreach (string result in Op(op, rest)) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        try
        {
            switch (op)
            {
                case "parse": return Parse(Latin(rest));
                case "format": return Format(Latin(rest));
                case "check": return Check(Latin(rest));
                case "number": return [FormFunctions.ParseNumber(Latin(rest)) is { } n ? FormFunctions.NumberText(n) : "null"];
                case "calc": return Calc(Latin(rest));
                case "csv": return Csv(Latin(rest));
                case "fill": return Fill(Latin(rest));
                case "reset": return Reset();
                case "author": return Author();
                case "style": return Style();
                case "flatten": return Flatten();
                case "export": return Export();
                case "detect": return Detect(Latin(rest));
                default: return [$"unknown op {op}"];
            }
        }
        catch (InvalidOperationException e)
        {
            return [$"refused {Golden.Escape(e.Message)}"];
        }
    }

    private static string Latin(string rest) => Encoding.Latin1.GetString(Golden.Unescape(rest));

    private static string Show(string? text) => text is null ? "-" : Golden.Escape(text);

    private static string N(double value) => new PdfNumber(value).ToString();

    private static string Numbers(IEnumerable<double>? values) => values is null ? "-" : "[" + string.Join(",", values.Select(N)) + "]";

    private static string Arg(object? value) => value switch
    {
        null => "null",
        double d => "n" + FormFunctions.NumberText(d),
        string s => "s" + Show(s),
        bool b => b ? "true" : "false",
        List<object?> list => "[" + string.Join(", ", list.Select(Arg)) + "]",
        _ => "?",
    };

    private static IEnumerable<string> Parse(string source)
    {
        var calls = FormScriptParser.Parse(source);
        if (calls is null) return ["null"];
        return calls.Select(c => c.Name + "(" + string.Join(", ", c.Args.Select(Arg)) + ")");
    }

    private static FormCall? CallOf(string source) => FormScriptParser.Parse(source)?[0];

    private static IEnumerable<string> Format(string rest)
    {
        int bar = rest.IndexOf('|');
        if (CallOf(rest[..bar]) is not { } call) return ["no call"];
        var formatted = FormFunctions.Format(call, rest[(bar + 1)..]);
        return [formatted is { } f ? Show(f.Text) + " " + Numbers(f.Color) : "null"];
    }

    private static IEnumerable<string> Check(string rest)
    {
        int bar = rest.IndexOf('|');
        if (CallOf(rest[..bar]) is not { } call) return ["no call"];
        return [Show(FormFunctions.Check(call, rest[(bar + 1)..]) ?? "ok")];
    }

    private static IEnumerable<string> Calc(string rest)
    {
        int bar = rest.IndexOf('|');
        string[] values = rest[(bar + 1)..].Length == 0 ? [] : rest[(bar + 1)..].Split(',');
        var names = values.Select((_, i) => ((char)('a' + i)).ToString()).ToList();
        string list = string.Join(", ", names.Select(n => $"\"{n}\""));
        var call = CallOf($"AFSimple_Calculate(\"{rest[..bar]}\", new Array({list}))")!;
        return [Show(FormFunctions.Calculate(call, name => [values[names.IndexOf(name)]]) ?? "null")];
    }

    private static IEnumerable<string> Csv(string text)
    {
        var rows = FormCsv.Read(text);
        var lines = rows.Select(r => "[" + string.Join(" | ", r.Select(Show)) + "]").ToList();
        lines.Add("again " + Show(FormCsv.Write(rows)));
        return lines;
    }

    private static string StreamLine(PdfDocument document, PdfStream stream) =>
        $"bbox={Numbers(document.Array(stream.Dictionary, "BBox")?.Items.Select(i => ((PdfNumber)i).Value))} matrix={Numbers(document.Array(stream.Dictionary, "Matrix")?.Items.Select(i => ((PdfNumber)i).Value))} | {Golden.Escape(document.Data(stream))}";

    private static IEnumerable<string> Dump(PdfForm form, string? only = null)
    {
        var document = form.Document;
        foreach (var field in form.Fields.Where(f => only is null || f.Name == only))
        {
            yield return $"field {Show(field.Name)} {field.Kind} ff={(int)field.Flags} value={Show(field.Value)} selected=[{string.Join(",", field.Selected.Select(Show))}] da={Show(field.DefaultAppearance)} " +
                $"max={field.MaxLength} q={field.Alignment} ti={document.Integer(field.Dictionary, "TI")?.ToString() ?? "-"} i={Numbers(document.Array(field.Dictionary, "I")?.Items.Select(i => ((PdfNumber)i).Value))}";
            foreach (var widget in field.Widgets)
            {
                yield return $"  widget rect={Numbers([widget.Rect.Left, widget.Rect.Bottom, widget.Rect.Right, widget.Rect.Top])} page={widget.PageIndex} as={document.Name(widget.Dictionary, "AS") ?? "-"} on={widget.OnState ?? "-"} export={widget.Export ?? "-"}";
                var normal = document.Resolve(document.Dict(widget.Dictionary, "AP")?["N"]);
                if (normal is PdfStream stream) yield return "    ap " + StreamLine(document, stream);
                else if (normal is PdfDictionary states)
                {
                    foreach (var entry in states.Entries)
                    {
                        if (document.Resolve(entry.Value) is PdfStream s) yield return $"    ap {entry.Key} " + StreamLine(document, s);
                    }
                }
            }
        }
    }

    private static IEnumerable<string> Fill(string rest)
    {
        string[] parts = rest.Split('\t');
        var form = PdfForm.Read(FormFixtures.Open());
        var result = form.SetValue(parts[0], parts.Length > 1 && parts[1].Length > 0 ? parts[1] : null);
        return [$"result filled={result.Filled} unknown=[{string.Join(",", result.UnknownFields)}] rejected=[{string.Join(",", result.Rejected)}] calculated={result.Calculated}", .. Dump(form, parts[0])];
    }

    private static PdfForm Filled()
    {
        var form = PdfForm.Read(FormFixtures.Open());
        form.SetValues([new("name", "Ada Lovelace"), new("agree", "Yes"), new("choice", "b"), new("city", "Izmir"), new("langs", "English; German"), new("code", "123")]);
        return form;
    }

    private static IEnumerable<string> Reset()
    {
        var form = Filled();
        int count = form.Reset();
        return [$"reset {count}", .. Dump(form)];
    }

    private static IEnumerable<string> Author()
    {
        var form = PdfForm.Read(AnnotationFixtures.Blank());
        double y = 700;
        PdfRect Next() => new(50, y -= 40, 250, y + 30);

        form.AddField(new FieldSpec(FieldKind.Text, "t", 0, Next()) { Flags = FieldFlags.Multiline, Value = "one two three four five six seven eight nine ten", Alignment = 1, BorderStyle = BorderStyle.Dashed });
        form.AddField(new FieldSpec(FieldKind.Text, "comb", 0, Next()) { MaxLength = 8, Flags = FieldFlags.Comb, Value = "123", Alignment = 2 });
        form.AddField(new FieldSpec(FieldKind.Text, "pw", 0, Next()) { Flags = FieldFlags.Password, Value = "secret", Background = [1, 1, 0.8], BorderStyle = BorderStyle.Beveled, BorderWidth = 2 });
        form.AddField(new FieldSpec(FieldKind.Text, "turned", 0, new PdfRect(50, 100, 80, 250)) { Rotation = 90, Value = "sideways", FontSize = 10, TextColor = [1, 0, 0], BorderStyle = BorderStyle.Underline });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "c", 0, Next()) { ExportValue = "On", Value = "On", Caption = "8" });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "diamond", 0, Next()) { Value = "Yes", Caption = "u", BorderStyle = BorderStyle.Inset });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "star", 0, Next()) { Value = "Yes", Caption = "H", Background = [0.9] });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "dingbat", 0, Next()) { Value = "Yes", Caption = "3" });
        form.AddField(new FieldSpec(FieldKind.Radio, "r", 0, Next()) { ExportValue = "one", Value = "one" });
        form.AddWidget(form.Find("r")!, 0, new PdfRect(300, 100, 314, 114), "two");
        form.AddField(new FieldSpec(FieldKind.PushButton, "go", 0, Next()) { Caption = "Send", Background = [0.8], BorderStyle = BorderStyle.Beveled });
        form.AddField(new FieldSpec(FieldKind.ComboBox, "combo", 0, Next()) { Options = [new("a"), new("b", "Bee")], Value = "Bee", DefaultValue = "a" });
        form.AddField(new FieldSpec(FieldKind.ListBox, "list", 0, Next()) { Options = [new("x"), new("y"), new("z")], Flags = FieldFlags.MultiSelect, Value = "x; z" });
        form.AddField(new FieldSpec(FieldKind.Signature, "sig", 0, Next()));
        form.AddField(new FieldSpec(FieldKind.Text, "group.child", 0, Next()) { Value = "nested", Tooltip = "tip" });
        return Dump(form);
    }

    private static IEnumerable<string> Style()
    {
        var form = PdfForm.Read(FormFixtures.Open());
        form.SetValues([new("name", "Ada"), new("agree", "Yes")]);
        form.SetFont(form.Find("name")!, "TiRo");
        form.SetFontSize(form.Find("name")!, 18);
        form.SetTextColor(form.Find("name")!, [1, 0, 0]);
        form.SetTextColor(form.Find("agree")!, [0.2, 0.4, 0.6]);
        form.SetExportValue(form.Find("agree")!.Widgets[0], "Accepted");
        return [.. Dump(form, "name"), .. Dump(form, "agree")];
    }

    private static IEnumerable<string> Flatten()
    {
        var form = Filled();
        int burned = form.Flatten();
        var page = form.Document.Pages[0];
        return [$"burned {burned} fields {form.Fields.Count} form {(form.AcroForm is null ? "none" : "kept")} annots {form.Document.Array(page.Dictionary, "Annots")?.Items.Count.ToString() ?? "-"}", "page " + Golden.Escape(page.Contents())];
    }

    private static IEnumerable<string> Export()
    {
        var form = Filled();
        return ["fdf " + Golden.Escape(PdfFdf.Write(form.ExportFdf("form.pdf"))), "csv " + Show(form.ExportCsv())];
    }

    private static IEnumerable<string> Detect(string content)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /DA (/Helv 0 Tf 0 g)>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots []>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        var found = FieldDetector.Detect(PdfDocument.Open(pdf.Finish()), 0);
        var lines = found.Select(p => $"{p.Kind} {Numbers([p.Rect.Left, p.Rect.Bottom, p.Rect.Right, p.Rect.Top])} name={Show(p.Name)} label={Show(p.Label)} cells={p.Cells} multiline={(p.Multiline ? "true" : "false")}").ToList();
        return lines.Count == 0 ? ["none"] : lines;
    }
}
