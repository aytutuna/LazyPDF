using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Standards/StandardsGolden.swift. One line of input is "<op> <words>" (the format is at the top of
// standards-input.txt): what the validator finds in a file for a level, what the converter does to it, the XMP packet and the sRGB
// profile byte for byte. The files are made here from the names in the input, with no font file (the C# tests read the Windows fonts;
// the converter is given none). A converted file is shown as every object of it, streams decoded (a long one with control bytes in it by its length) and
// without /Length and the Flate filter, because the deflate of the two sides is not the same one. The texts are English whatever the machine's language is, and the numbers in them have the invariant format.
internal static class StandardsGolden
{
    private static readonly DateTimeOffset Day = new(2026, 3, 9, 14, 5, 7, TimeSpan.FromHours(3));

    public static string Run(string input)
    {
        var culture = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        Loc.Table = new Dictionary<string, string>();
        try
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
        finally
        {
            Loc.Table = null;
            CultureInfo.CurrentCulture = culture;
        }
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        string[] words = rest.Split(' ');
        switch (op)
        {
            case "check": return Check(Level(words[0]), words[1]);
            case "convert": return Convert(Level(words[0]), words[1]);
            case "packet": return [Packet(Level(words[0]), words[1] == "true")];
            case "strip": return [Strip(rest)];
            case "profile": return [System.Convert.ToHexStringLower(PdfASrgb.SrgbProfile)];
            default: return [$"unknown op {op}"];
        }
    }

    private static PdfALevel Level(string name) => Enum.Parse<PdfALevel>(name, ignoreCase: true);

    private static byte[] Plain(string content = "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET", string catalog = "", string page = "", string resources = "", Action<TestPdf>? extra = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> {resources}>> {page}>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        extra?.Invoke(pdf);
        return pdf.Finish("/Root 1 0 R");
    }

    private static byte[] Case(string name, PdfALevel level)
    {
        switch (name)
        {
            case "compliant":
                return StandardsKit.Compliant(level);
            case "no-intent":
                return StandardsKit.Compliant(level, intents: "");
            case "broken":
                return StandardsKit.Compliant(level,
                    catalog: "/AA << /WC << /S /URI /URI (x) >> >> /NeedsRendering false /OpenAction << /S /JavaScript /JS (1) >> /Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>",
                    page: "/Annots [9 0 R 10 0 R 11 0 R] /AA << /O << /S /URI /URI (x) >> >>",
                    content: "/G0 gs 0 0 0 1 k 0 0 5 5 re f BX 1 2 frob EX",
                    resources: "/ExtGState <</G0 <</ca 0.5 /CA 0.5 /BM /Glow /TR /Identity /HTP /Default>>>>",
                    extra: pdf =>
                    {
                        pdf.Obj(9, "<</Type /Annot /Subtype /Sound /Rect [10 10 50 50] /F 4>>");
                        pdf.Obj(10, "<</Type /Annot /Subtype /Square /Rect [60 10 90 50] /F 0 /C [1 0 0]>>");
                        pdf.Obj(11, "<</Type /Annot /Subtype /Link /Rect [10 60 50 90] /F 4 /Border [0 0 0] /A << /S /Launch /F (a.exe) /Next << /S /Named /N /Print >> >>>>");
                    });
            case "streams":
                return StandardsKit.Compliant(level, catalog: "/Extra 9 0 R /More 12 0 R", extra: pdf =>
                {
                    pdf.Stream(9, "/Filter /LZWDecode /F (a.txt)", PdfFilterEncoders.Lzw("abc"u8));
                    pdf.Stream(12, "/Filter /Fl", "abc");
                    pdf.Obj(4, "<</Length 5>>\nstream \n0 0 1 rg 20 20 100 100 re f\nendstream");
                });
            case "metadata":
                return StandardsKit.Compliant(level,
                    xmp: StandardsKit.Packet(level).Replace("<pdfaid:part>2<", "<pdfaid:part>1<").Replace("<pdfaid:conformance>B<", "<pdfaid:conformance>X<"),
                    info: "<</Title (Other) /Author (Someone) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103001Z) /ModDate (D:20260304103000Z)>>");
            case "layers":
                return StandardsKit.Compliant(level, catalog: "/OCProperties << /OCGs [9 0 R] /D << /Order [] /AS [<< /Event /View >>] >> >>", extra: pdf => pdf.Obj(9, "<</Type /OCG /Name (L)>>"));
            case "attachment":
                return StandardsKit.Compliant(level, catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 9 0 R] >> >>", extra: pdf =>
                {
                    pdf.Obj(9, "<</Type /Filespec /F (a.dat) /UF (a.dat) /EF << /F 10 0 R >> >>");
                    pdf.Stream(10, "/Type /EmbeddedFile", "hello");
                });
            case "form":
                return StandardsKit.Compliant(level, catalog: "/AcroForm << /Fields [9 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) /XFA [(a) 10 0 R] >>", page: "/Annots [9 0 R]", extra: pdf =>
                {
                    pdf.Obj(9, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (abc) /Rect [10 10 100 30] /F 4 /AA << /K << /S /URI /URI (x) >> >>>>");
                    pdf.Stream(10, "", "x");
                });
            case "limits":
                return StandardsKit.Compliant(level, catalog: $"/Key /{new string('a', 130)} /Big 3000000000 /Real 40000.5 /Text ({new string('t', 70000)})", page: "/Odd <ABC>",
                    content: string.Concat(Enumerable.Repeat("q ", 29)) + string.Concat(Enumerable.Repeat("Q ", 29)) + "0 0 1 rg 20 20 40000.5 100 re f");
            case "inline":
                return StandardsKit.Compliant(level, content: "q BI /W 1 /H 1 /BPC 8 /CS /G /I true /F /Crypt ID x EI Q BI /W 1 /H 1 /BPC 8 /CS /RGB ID abc EI Q");
            case "a-good":
                return StandardsKit.Tagged(level);
            case "a-unmarked":
                return StandardsKit.Tagged(level, marked: "");
            case "a-nolang":
                return StandardsKit.Tagged(level, lang: "");
            case "a-loose":
                return StandardsKit.Tagged(level, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC 1 0 0 rg 130 20 50 50 re f");
            case "a-noalt":
                return StandardsKit.Tagged(level, alt: "");
            case "a-rolemap":
                return StandardsKit.Tagged(level, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart");
            case "a-rolemap-ok":
                return StandardsKit.Tagged(level, roleMap: "/RoleMap <</Chart /Figure>>", figureType: "Chart");
            case "a-part2-type":
                return StandardsKit.Tagged(level, figureType: "Annot");
            case "plain":
                return Plain();
            case "plain-lang":
                return Plain(catalog: "/Lang (en-US)");
            case "transparency":
                return Plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>");
            case "lzw":
                return Plain(extra: pdf => pdf.Stream(4, "/Filter /LZWDecode", PdfFilterEncoders.Lzw("BT /F1 12 Tf 20 100 Td (Hello world) Tj ET"u8)));
            default:
                throw new ArgumentException($"no case {name}");
        }
    }

    private static IEnumerable<string> Check(PdfALevel level, string name)
    {
        using var document = PdfDocument.Open(Case(name, level));
        var report = PdfAValidator.Validate(document, level);
        yield return $"issues {report.Issues.Count} truncated {(report.Truncated ? "true" : "false")}";
        foreach (var issue in report.Issues) yield return $"  {issue.Clause} | {Show(issue.Where)} | {Show(issue.Message)}";
    }

    private static IEnumerable<string> Convert(PdfALevel level, string name)
    {
        var result = new PdfAConverter().Convert(Case(name, level), level, Day);
        yield return $"refusal {Show(result.Refusal ?? "none")}";
        foreach (string change in result.Changes) yield return $"change {Show(change)}";
        yield return $"remaining {result.Remaining.Count} clean {(result.IsClean ? "true" : "false")}";
        foreach (var issue in result.Remaining) yield return $"  {issue.Clause} | {Show(issue.Where)} | {Show(issue.Message)}";
        if (result.Bytes is not { } bytes) yield break;
        yield return "header " + Show(Encoding.Latin1.GetString(bytes, 0, 8));
        using var document = PdfDocument.Open(bytes);
        foreach (string line in Dump(document).Split('\n')) yield return "  " + line;
    }

    private static string Packet(PdfALevel level, bool declare)
    {
        var meta = new DocumentMetadata("A & B <c> \"d\" \U0001F600", "Au\r\nthor\tx", "  Sub\u0001ject  ", "k1, k2", null, "Prod",
            new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.FromHours(-5)), Day, new Dictionary<string, string>());
        return Golden.Escape(PdfAPacket.Xmp(level, meta, Day, declare));
    }

    private static string Strip(string escaped)
    {
        string? result = PdfAPacket.Strip(Encoding.UTF8.GetString(Golden.Unescape(escaped)));
        return result is null ? "null" : Golden.Escape(Encoding.UTF8.GetBytes(result));
    }

    private static string Show(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static string Data(PdfDocument document, PdfStream stream)
    {
        try
        {
            byte[] data = document.Data(stream);
            return data.Length > 300 && data.Any(b => b < 0x20 && b is not (9 or 10 or 13)) ? $"{data.Length} bytes" : Show(Encoding.Latin1.GetString(data));
        }
        catch (PdfReadException)
        {
            return "unreadable";
        }
    }

    // The dictionary without /Length, the size of the deflate of each side, and without a Flate filter, which the saver keeps only when the
    // deflate is smaller than the data, and the two deflates differ.
    private static string Entries(PdfDictionary dictionary) =>
        "<<" + string.Join(" ", dictionary.Entries.Where(e => e.Key != "Length" && !(e.Key == "Filter" && e.Value is PdfName { Value: "FlateDecode" })).Select(e => $"{new PdfName(e.Key)} {e.Value}")) + ">>";

    private static string Dump(PdfDocument document)
    {
        var sb = new StringBuilder();
        foreach (int number in document.ObjectNumbers)
        {
            string text = document.Get(number) switch
            {
                PdfStream s => $"stream {Entries(s.Dictionary)} | {Data(document, s)}",
                null => "null",
                var value => value.ToString()!,
            };
            sb.Append(number).Append(": ").Append(text).Append('\n');
        }
        return sb.ToString().TrimEnd('\n');
    }
}
