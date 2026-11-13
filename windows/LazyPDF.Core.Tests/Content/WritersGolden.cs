using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

// Mirrored by the Swift suite. One line of input is "<writer> <text>" (the writers are listed at the top of
// writers-input.txt); the writer puts the text on a blank page with the script font of the shaping golden for every family,
// and the output is every object of the file with streams decoded. Font programs are only named, since the two engines
// subset differently.
internal static class WritersGolden
{
    private sealed class OneFont(byte[] data) : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) => new(data);
    }

    public static string Run(byte[] font, string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith('#')) continue;
            int space = line.IndexOf(' ');
            string op = line[..space];
            string text = line[(space + 1)..].Replace("\\n", "\n");
            output.Append("> ").Append(line).Append('\n');
            output.Append(Dump(Write(op, new OneFont(font), text))).Append('\n');
        }
        return output.ToString();
    }

    private static PdfDocument Write(string op, IFontSource fonts, string text)
    {
        var document = AnnotationFixtures.Blank(1);
        switch (op)
        {
            case "freetext":
                new PdfAnnotationWriter(document, fonts).AddFreeText(document.Pages[0], new PdfRect(50, 600, 250, 700), text, new FreeTextStyle("Script Sans", 14));
                break;
            case "textbox":
                var session = PdfEditSession.Open(AnnotationFixtures.Blank(1).SaveRewrite());
                new PageEditor(session, 0, fonts).AddTextBox(new PdfRect(50, 600, 250, 700), text, new TextBoxStyle("Script Sans", Size: 14));
                return PdfDocument.Open(session.Current.ToArray());
            case "edit":
                var edit = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET");
                Assert.True(new PageEditor(edit, 0, fonts).ReplaceText(EditKit.Find(edit, "world"), text).Done);
                return PdfDocument.Open(edit.Current.ToArray());
            case "watermark":
                new PdfStamper(document, fonts).AddWatermark(new WatermarkSpec { Text = text, FontFamily = "Script Sans" });
                break;
            case "header":
                new PdfStamper(document, fonts).AddHeaderFooter(new HeaderFooterSpec { Header = new("", text, ""), Footer = new(text, "", ""), FontFamily = "Script Sans" });
                break;
            case "field" or "multiline" or "comb" or "combo":
                Field(document, fonts, op, text);
                break;
            case "plain":
                return PdfDocument.Open(PdfFromText.Create(text, fonts, family: "Script Sans").Bytes);
        }
        return document;
    }

    private static void Field(PdfDocument document, IFontSource fonts, string op, string text)
    {
        var form = PdfForm.Read(document, fonts);
        var rect = new PdfRect(50, 600, 250, op == "multiline" ? 700 : 630);
        form.AddField(op switch
        {
            "multiline" => new FieldSpec(FieldKind.Text, "f", 0, rect) { Flags = FieldFlags.Multiline, Value = text, FontSize = 12 },
            "comb" => new FieldSpec(FieldKind.Text, "f", 0, rect) { MaxLength = 8, Flags = FieldFlags.Comb, Value = text, FontSize = 12 },
            "combo" => new FieldSpec(FieldKind.ComboBox, "f", 0, rect) { Options = [new(text)], Value = text, FontSize = 12 },
            _ => new FieldSpec(FieldKind.Text, "f", 0, rect) { Value = text, FontSize = 12 },
        });
    }

    private static string Dump(PdfDocument document)
    {
        var sb = new StringBuilder();
        foreach (int number in document.ObjectNumbers)
        {
            string text = document.Get(number) switch
            {
                PdfStream s when s.Dictionary.ContainsKey("Length1") => "stream font program",
                PdfStream s => $"stream {s.Dictionary} | {Golden.Escape(Encoding.Latin1.GetString(document.Data(s)))}",
                null => "null",
                var value => value.ToString()!,
            };
            sb.Append(number).Append(": ").Append(text).Append('\n');
        }
        // The subset tag and the annotation name are random; the stream length and whether a short stream is deflated at all
        // depend on the deflate of each engine.
        string dump = Regex.Replace(sb.ToString().TrimEnd('\n'), @"/[A-Z]{6}\+", "/AAAAAA+");
        return Regex.Replace(Regex.Replace(dump, @"/NM \([^)]*\)", "/NM (id)"), @" ?/(Length \d+|Filter /FlateDecode)", "");
    }
}
