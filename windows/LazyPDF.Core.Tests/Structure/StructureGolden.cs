using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Structure/StructureGolden.swift. One line of input is "<op> <words>" (the format is
// at the top of structure-input.txt): text strings and dates, XMP packets rewritten by the metadata writer, actions and
// destinations read from small objects, and fixed scenarios whose objects are printed. Numbers go through PdfNumber,
// which both sides write alike. Line ends in a rewritten XMP packet are LF: XmlWriter ends a line with
// Environment.NewLine, which is CRLF on Windows.
internal static class StructureGolden
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
                case "text": return [Show(PdfText.Decode(Golden.Unescape(rest)))];
                case "encode": return [Hex(PdfText.Encode(Utf8(rest)))];
                case "object": return [PdfText.ToObject(Utf8(rest)).ToString()];
                case "key": return [Show(PdfNameTree.KeyOf(Utf8(rest))), Show(PdfNameTree.TextOf(PdfNameTree.KeyOf(Utf8(rest))))];
                case "date": return [Date(rest)];
                case "xmpdate": return [XmpDate(rest)];
                case "labels": return Labels(rest);
                case "meta": return Meta(rest);
                case "action": return Action(rest);
                case "dest": return Dest(rest, false);
                case "destr": return Dest(rest, true);
                case "scenario": return Scenario(rest);
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    private static string Utf8(string rest) => Encoding.UTF8.GetString(Golden.Unescape(rest));

    private static string Latin(string rest) => Encoding.Latin1.GetString(Golden.Unescape(rest));

    // A string with every character outside printable ASCII as \uXXXX of its UTF-16 unit.
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

    private static string Hex(byte[] bytes) => string.Concat(bytes.Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));

    private static string Iso(DateTimeOffset date) => date.ToString("o", CultureInfo.InvariantCulture);

    private static string Date(string rest)
    {
        var date = PdfDate.Parse(Latin(rest));
        return date is { } d ? $"{Iso(d)} {PdfDate.Format(d)} {PdfDate.FormatXmp(d)}" : "null";
    }

    private static string XmpDate(string rest) => PdfDate.ParseXmp(Latin(rest)) is { } d ? Iso(d) : "null";

    private static string N(double? value) => value is { } v ? new PdfNumber(v).ToString() : "-";

    private static string B(bool? value) => value is { } v ? (v ? "true" : "false") : "-";

    private static string D(PdfDestination? d) =>
        d is null ? "-" : $"page={d.PageIndex} fit={d.Fit} left={N(d.Left)} bottom={N(d.Bottom)} right={N(d.Right)} top={N(d.Top)} zoom={N(d.Zoom)} name={(d.Name is { } n ? Show(n) : "-")}";

    private static string Dump(PdfDocument document, int from = 1)
    {
        var sb = new StringBuilder();
        foreach (int number in document.ObjectNumbers.Where(n => n >= from))
        {
            var value = document.Get(number);
            sb.Append(number).Append(": ").Append(value is PdfStream ? "stream" : value?.ToString() ?? "null").Append('\n');
        }
        return sb.ToString().TrimEnd('\n');
    }

    private static IEnumerable<string> Lines(string text) => text.Split('\n');

    // start:style:prefix:first;... | pages. The labels of the pages, then the objects a write of the ranges makes.
    private static IEnumerable<string> Labels(string rest)
    {
        string[] parts = rest.Split(" | ");
        var ranges = parts[0].Split(';').Select(r =>
        {
            string[] f = r.Split(':');
            var style = f[1] switch
            {
                "D" => PageLabelStyle.Decimal,
                "R" => PageLabelStyle.UpperRoman,
                "r" => PageLabelStyle.LowerRoman,
                "A" => PageLabelStyle.UpperLetters,
                "a" => PageLabelStyle.LowerLetters,
                _ => PageLabelStyle.None,
            };
            return new PageLabelRange(int.Parse(f[0], CultureInfo.InvariantCulture), style, f[2], int.Parse(f[3], CultureInfo.InvariantCulture));
        }).ToList();
        int pages = int.Parse(parts[1], CultureInfo.InvariantCulture);
        var document = StructureFixtures.Open(2);
        PdfPageLabels.Write(document, ranges);
        return [string.Join(",", Enumerable.Range(0, pages).Select(i => Show(PdfPageLabels.Label(ranges, i)))), .. Lines(Dump(document))];
    }

    // Writes a fixed record into a file whose /Metadata is the bytes, and shows /Info and what became of the packet.
    private static IEnumerable<string> Meta(string rest)
    {
        var document = StructureFixtures.File("/Metadata 30 0 R", pdf => pdf.Stream(30, "/Type /Metadata /Subtype /XML", Golden.Unescape(rest)), pages: 1);
        new DocumentMetadata(
            "Golden title", "A. Writer", "Subject & more <x>", "one, two;three,, ;four", "Tool", "Lazy PDF",
            new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.FromHours(3)), new DateTimeOffset(2026, 2, 3, 4, 5, 6, TimeSpan.FromHours(-5)),
            new Dictionary<string, string> { ["Department"] = "Finance", ["bad key"] = "x", ["Note"] = "Türkçe", ["Empty"] = "", ["Ctl"] = "a\u0001b\r\nc" }).Write(document);
        string packet = Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!)).Replace("\r\n", "\n");
        var read = DocumentMetadata.Read(document);
        return
        [
            "info " + document.Info,
            "xmp " + Show(packet),
            $"read {Show(read.Title ?? "-")}|{Show(read.Author ?? "-")}|{Show(read.Subject ?? "-")}|{Show(read.Keywords ?? "-")}|{(read.Created is { } c ? Iso(c) : "-")}|{(read.Modified is { } m ? Iso(m) : "-")}|{string.Join(",", read.Custom.Select(e => e.Key + "=" + Show(e.Value)))}",
        ];
    }

    private static string Describe(PdfAction action)
    {
        string text = action switch
        {
            GoToAction a => "GoTo " + D(a.Destination),
            GoToRemoteAction a => $"GoToR file={Show(a.File)} new={B(a.NewWindow)} dest={D(a.Destination)}",
            LaunchAction a => $"Launch file={(a.File is { } f ? Show(f) : "-")} new={B(a.NewWindow)}",
            UriAction a => "Uri " + Show(a.Uri),
            NamedAction a => "Named " + Show(a.Name),
            JavaScriptAction a => "JavaScript " + Show(a.Script),
            SubmitFormAction a => $"SubmitForm url={Show(a.Url)} flags={a.Flags} fields=[{string.Join("|", a.Fields.Select(Show))}]",
            ResetFormAction a => $"ResetForm flags={a.Flags} fields=[{string.Join("|", a.Fields.Select(Show))}]",
            OtherAction a => "Other " + Show(a.Type),
            _ => "?",
        };
        return text + " next=[" + string.Join(", ", action.Next.Select(Describe)) + "]";
    }

    // <object 20> ;; <n>=<object> ;; <n>=stream(<bytes>) ...: the action in object 20, as read and as written again.
    private static IEnumerable<string> Action(string rest)
    {
        string[] parts = rest.Split(" ;; ");
        var document = StructureFixtures.File("/OpenAction 20 0 R", pdf =>
        {
            pdf.Obj(20, parts[0]);
            foreach (string extra in parts.Skip(1))
            {
                int eq = extra.IndexOf('=');
                int number = int.Parse(extra[..eq], CultureInfo.InvariantCulture);
                string body = extra[(eq + 1)..];
                if (body.StartsWith("stream(", StringComparison.Ordinal)) pdf.Stream(number, "", Golden.Unescape(body[7..^1]));
                else pdf.Obj(number, body);
            }
        });
        var action = PdfActions.Read(document, new PdfReference(20, 0));
        if (action is null) return ["null"];
        var results = new List<string> { Describe(action) };
        results.Add("written " + Written(document, action));
        results.Add("javascript " + (PdfActions.HasJavaScript(document) ? "yes" : "no"));
        return results;
    }

    // ToObject refuses an action it cannot write, and a GoTo to a page that is not there.
    private static string Written(PdfDocument document, PdfAction action)
    {
        try
        {
            return PdfActions.ToObject(document, action).ToString();
        }
        catch (ArgumentException)
        {
            return "refused";
        }
    }

    // <object 20>: the destination in it, as written again and where it lands.
    private static IEnumerable<string> Dest(string rest, bool remote)
    {
        var document = StructureFixtures.File("", pdf => pdf.Obj(20, rest));
        var destination = PdfDestinations.Parse(document, new PdfReference(20, 0), remote);
        if (destination is null) return ["null"];
        var results = new List<string> { D(destination), "written " + (PdfDestinations.ToObject(document, destination, remote)?.ToString() ?? "null") };
        if (!remote)
        {
            results.Add("located " + (PdfDestinations.Locate(document, destination) is { } p ? $"{p.PageIndex} {N(p.X)} {N(p.Y)} {N(p.Zoom)}" : "null"));
        }
        return results;
    }

    private static IEnumerable<string> Scenario(string name)
    {
        switch (name)
        {
            case "nametree":
            {
                var document = StructureFixtures.Open(1);
                var root = PdfNameTree.Write(document, null, Enumerable.Range(0, 150).Reverse().Select(i => new KeyValuePair<string, PdfObject>($"n{i:D3}", new PdfNumber(i))));
                PdfNames.Ensure(document)["Dests"] = document.Add(root);
                return Lines(Dump(document));
            }
            case "numbertree":
            {
                var document = StructureFixtures.Open(1);
                var root = PdfNumberTree.Write(document, null, Enumerable.Range(0, 150).Select(i => new KeyValuePair<long, PdfObject>(i * 3L, new PdfNumber(i))));
                PdfNames.Ensure(document)["Nums"] = document.Add(root);
                return Lines(Dump(document));
            }
            case "actions": return Actions();
            case "destinations":
            {
                var document = StructureFixtures.Open(3);
                document.Catalog["Dests"] = new PdfDictionary { ["old"] = new PdfArray([document.Pages[0].Reference, new PdfName("Fit")]) };
                for (int i = 0; i < 70; i++) PdfDestinations.SetNamed(document, $"d{i:D3}", new PdfDestination(i % 3, DestinationFit.FitH, Top: i));
                PdfDestinations.SetNamed(document, "old", new PdfDestination(2));
                PdfDestinations.RemoveNamed(document, "d005");
                var named = PdfDestinations.Named(document);
                return [$"{named.Count} {named[0].Key} {D(named[0].Value)} {named[^1].Key} {D(named[^1].Value)}", .. Lines(Dump(document))];
            }
            case "outline": return OutlineScenario();
            case "links": return LinksScenario();
            case "viewer": return ViewerScenario();
            default: return [$"unknown scenario {name}"];
        }
    }

    private static IEnumerable<string> Actions()
    {
        var document = StructureFixtures.Open(3);
        PdfAction[] actions =
        [
            new GoToAction(new PdfDestination(2, DestinationFit.FitH, Top: 7)),
            new GoToAction(new PdfDestination(1, DestinationFit.FitR, 1, 2, 3, 4)),
            new GoToRemoteAction("o.pdf", new PdfDestination(3), true),
            new GoToRemoteAction("oé.pdf", new PdfDestination(-1, Name: "chap"), null),
            new LaunchAction("x.exe", null),
            new LaunchAction(null, false),
            new UriAction("https://example.com/é?a=1&b=(2)"),
            new NamedAction("PrevPage"),
            new JavaScriptAction("var s = \"é\";\n\\"),
            new JavaScriptAction("Ж"),
            new SubmitFormAction("http://x/post", 4, ["a", "bЖ"]),
            new ResetFormAction(0, []),
            new ResetFormAction(1, ["f"]),
            new NamedAction("A") { Next = [new UriAction("u"), new NamedAction("B") { Next = [new NamedAction("C")] }] },
            new NamedAction("Only") { Next = [new NamedAction("One")] },
        ];
        return actions.Select(a => PdfActions.ToObject(document, a).ToString());
    }

    private static IEnumerable<string> OutlineScenario()
    {
        var document = StructureFixtures.File("/Outlines 20 0 R /Names <</Dests <</Names [(target) [4 0 R /Fit]]>>>>", pdf =>
        {
            pdf.Obj(20, "<</Type /Outlines /First 21 0 R /Last 23 0 R /Count 99>>");
            pdf.Obj(21, "<</Title (Chapter 1) /Parent 20 0 R /Next 22 0 R /First 24 0 R /Last 25 0 R /Count 7 /Dest [3 0 R /XYZ 0 300 null] /C [1 0 0] /F 3 /Unknown (kept)>>");
            pdf.Obj(22, "<</Title (Chapter 2) /Parent 20 0 R /Prev 21 0 R /Next 23 0 R /First 26 0 R /Last 26 0 R /Count -1 /Dest (target) /SE 21 0 R>>");
            pdf.Obj(23, "<</Title (Chapter 3) /Parent 20 0 R /Prev 22 0 R /Dest [5 0 R /Fit]>>");
            pdf.Obj(24, "<</Title (Section 1.1) /Parent 21 0 R /Next 25 0 R /A <</S /URI /URI (http://example.com)>>>>");
            pdf.Obj(25, "<</Title <FEFF04160410> /Parent 21 0 R /Prev 24 0 R /A <</S /GoTo /D [5 0 R /FitH 10]>>>>");
            pdf.Obj(26, "<</Title (Appendix \\(a\\)) /Parent 22 0 R>>");
        });
        var outline = Outline.Read(document);
        var read = new List<string> { Titles(outline.Root) };
        outline.Move(outline.Items[2], outline.Items[0], 0);
        outline.Add(new OutlineItem { Title = "Türkçe", Destination = StructureFixtures.ToPage(1), Bold = true, Color = (0, 0.5, 1), IsOpen = true });
        outline.Add(new OutlineItem { Title = "Link", Action = new UriAction("http://x") }, outline.Items[^1]);
        outline.Items[1].Title = "Renamed";
        outline.Items[0].Children[2].Destination = null;
        outline.Remove(outline.Items[0].Children[1]);
        outline.Write(document);
        read.Add(Titles(outline.Root));
        read.AddRange(Lines(Dump(document, 20)));
        return read;
    }

    private static string Titles(OutlineItem item) =>
        string.Join(",", item.Children.Select(c => Show(c.Title) + (c.Children.Count > 0 ? "(" + Titles(c) + ")" : "")));

    private static IEnumerable<string> LinksScenario()
    {
        var document = StructureFixtures.Open(3);
        var page = document.Pages[0];
        PdfLinks.Add(document, page, new PdfRect(10, 10, 60, 30), new PdfDestination(2, DestinationFit.FitH, Top: 5));
        PdfLinks.AddUri(document, page, new PdfRect(70, 10, 120, 30), "https://example.com/é");
        var removed = PdfLinks.Add(document, page, new PdfRect(1, 1, 2, 2), new NamedAction("NextPage"));
        PdfLinks.Add(document, document.Pages[1], new PdfRect(5.5, 6.25, 7, 8), new GoToRemoteAction("o.pdf", new PdfDestination(0), null));
        PdfLinks.Remove(document, page, removed);
        var results = new List<string> { Dump(document, 3) };
        foreach (var link in PdfLinks.Read(document, page)) results.Add($"link {link.Rect.ToArray()} {D(link.Destination)} {(link.Action is { } a ? Describe(a) : "-")} {link.Uri ?? "-"} {link.Reference}");
        return results.SelectMany(Lines);
    }

    private static IEnumerable<string> ViewerScenario()
    {
        var results = new List<string>();
        var document = StructureFixtures.Open(1);
        new ViewerSettings("en-US", true, PageMode.FullScreen, PageLayout.TwoPageRight, true, true, true, true, true, true, true, "DuplexFlipShortEdge", 3).Write(document);
        results.Add(document.Catalog.ToString());
        new ViewerSettings(null, false, PageMode.UseNone, PageLayout.SinglePage, false, false, false, false, false, false, false, null, null).Write(document);
        results.Add(document.Catalog.ToString());
        new ViewerSettings("Ж", false, PageMode.UseThumbs, PageLayout.OneColumn, false, false, false, false, true, false, false, "Simplex", 9).Write(document);
        results.Add(document.Catalog.ToString());
        return results;
    }
}
