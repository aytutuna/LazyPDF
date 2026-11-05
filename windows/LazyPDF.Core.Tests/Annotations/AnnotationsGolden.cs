using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Annotations/AnnotationsGolden.swift. One line of input is "<op> <words>" (the format is
// at the top of annotations-input.txt): appearance streams drawn for each kind, edits, the words of /DA and CSS, rich text,
// comment lists, flattening, FDF and XFDF read and written, attachments, layers and document facts. Streams are shown
// decoded, because the deflate of the two sides is not the same one; the random /NM of a new annotation is made "nm" first;
// line ends in XFDF are LF, because XmlWriter ends a line with Environment.NewLine.
internal static class AnnotationsGolden
{
    private static readonly DateTimeOffset Day = new(2026, 3, 4, 10, 0, 0, TimeSpan.Zero);
    private static readonly AnnotationInfo Info = new("Ayşe", "check this", "Review", Day);

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
                case "rich": return [Show(PdfRichText.ToPlain(Utf8(rest)))];
                case "da": return DaOp(Latin(rest));
                case "css": return FormatLines(TextFormat.Default.WithCss(Utf8(rest)));
                case "ap": return Ap(rest);
                case "edit": return Edit();
                case "comments": return Comments();
                case "flatten": return Flatten(rest);
                case "fdf": return Fdf(Golden.Unescape(rest));
                case "export": return Export();
                case "xfdf": return Xfdf(Golden.Unescape(rest));
                case "attach": return Attach();
                case "layers": return Layers();
                case "facts": return Facts(rest);
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {Show(e.Message.StartsWith("The XFDF is not well-formed", StringComparison.Ordinal) ? "The XFDF is not well-formed" : e.Message)}"];
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

    private static string N(double? value) => value is { } v ? new PdfNumber(v).ToString() : "-";

    private static string Numbers(IEnumerable<double>? values) => values is null ? "-" : "[" + string.Join(",", values.Select(v => N(v))) + "]";

    private static string Iso(DateTimeOffset? date) => date is { } d ? d.ToString("o", CultureInfo.InvariantCulture) : "-";

    private static IEnumerable<string> Lines(string text) => text.Split('\n');

    private static IEnumerable<string> ShowLines(string text) => text.Split('\n').Select(Show);

    private static string Dump(PdfDocument document, int from = 1)
    {
        var sb = new StringBuilder();
        foreach (int number in document.ObjectNumbers.Where(n => n >= from))
        {
            var value = document.Get(number);
            string text = value switch
            {
                PdfStream s => $"stream {s.Dictionary} | {Show(Encoding.Latin1.GetString(document.Data(s)))}",
                null => "null",
                PdfDictionary d => Fold(d),
                _ => value.ToString()!,
            };
            sb.Append(number).Append(": ").Append(text).Append('\n');
        }
        return sb.ToString().TrimEnd('\n');
    }

    // A dictionary as text; a rich text read from XFDF has the line ends of the machine in it, so they become LF first.
    private static string Fold(PdfDictionary d)
    {
        var copy = d.Copy();
        if (copy["RC"] is PdfString rich) copy["RC"] = PdfText.ToObject(PdfText.Decode(rich.Bytes).Replace("\r\n", "\n"));
        return copy.ToString();
    }

    // The random /NM of annotations the writer made becomes "nm", so that the dump can be compared.
    private static void Fix(PdfDocument document)
    {
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is PdfDictionary d && d.ContainsKey("NM") && d.ContainsKey("Subtype")) d["NM"] = PdfText.ToObject("nm");
        }
    }

    private static string FormatLine(TextFormat f) =>
        $"format {Show(f.Family)}|{N(f.Size)}|{f.Bold}|{f.Italic}|{f.Underline}|{Numbers(f.Color)}";

    private static IEnumerable<string> FormatLines(TextFormat f) =>
    [
        FormatLine(f), "build " + Show(DefaultAppearance.Build(f)), "style " + Show(DefaultAppearance.BuildStyle(f, 1)),
    ];

    private static IEnumerable<string> DaOp(string da)
    {
        var (font, size, color) = DefaultAppearance.Parse(da);
        var f = TextFormat.Default;
        if (font is not null) f = DefaultAppearance.FormatOf(font, f);
        if (size is > 0) f = f with { Size = size.Value };
        if (color is not null) f = f with { Color = color };
        return [$"parsed {(font is null ? "-" : Show(font))} {N(size)} {Numbers(color)} standard={(font is not null && DefaultAppearance.IsStandard(font))}", .. FormatLines(f)];
    }

    private static IEnumerable<string> Ap(string name)
    {
        var document = AnnotationFixtures.Blank(1);
        var writer = new PdfAnnotationWriter(document);
        var page = document.Pages[0];
        MarkupQuad[] quads = [MarkupQuad.FromRect(new PdfRect(100, 500, 300, 514)), MarkupQuad.FromRect(new PdfRect(100, 480, 200, 494))];
        (double, double)[] points = [(100, 600), (150, 650), (200, 600), (250, 650)];
        switch (name)
        {
            case "highlight": writer.AddTextMarkup(page, AnnotationType.Highlight, quads, Info, new AnnotationStyle(Opacity: 0.5)); break;
            case "underline": writer.AddTextMarkup(page, AnnotationType.Underline, quads, Info, new AnnotationStyle([0, 0.5, 1])); break;
            case "strikeout": writer.AddTextMarkup(page, AnnotationType.StrikeOut, quads, Info); break;
            case "squiggly": writer.AddTextMarkup(page, AnnotationType.Squiggly, quads, Info); break;
            case "square": writer.AddSquare(page, new PdfRect(100, 600, 200, 650), new AnnotationStyle([0, 0, 1], 4, null, [1, 1, 0]), Info); break;
            case "square-dash": writer.AddSquare(page, new PdfRect(100, 600, 200, 650), new AnnotationStyle(Dash: [4, 2], Opacity: 0.5)); break;
            case "square-cloud": writer.AddSquare(page, new PdfRect(100, 600, 260, 700), new AnnotationStyle(Cloud: 2)); break;
            case "circle": writer.AddCircle(page, new PdfRect(100, 600, 160, 660), new AnnotationStyle([1, 0, 0], 2, Fill: [0, 1, 0])); break;
            case "circle-cloud": writer.AddCircle(page, new PdfRect(100, 600, 260, 700), new AnnotationStyle(Cloud: 1)); break;
            case "line": writer.AddLine(page, (100, 600), (300, 650), new AnnotationStyle(Width: 2), Info); break;
            case "endings":
                foreach (var ending in new[] { LineEnding.Square, LineEnding.Circle, LineEnding.Diamond, LineEnding.OpenArrow, LineEnding.ClosedArrow, LineEnding.Butt, LineEnding.ROpenArrow, LineEnding.RClosedArrow, LineEnding.Slash })
                {
                    writer.AddLine(page, (100, 600), (300, 650), new AnnotationStyle([1, 0, 0], 2, Fill: [0, 1, 0]), null, ending, ending);
                }
                break;
            case "arrow": writer.AddArrow(page, (100, 600), (300, 600), new AnnotationStyle(Width: 2)); break;
            case "polyline": writer.AddPolyLine(page, points, new AnnotationStyle([0, 0, 1]), Info, LineEnding.None, LineEnding.ClosedArrow); break;
            case "polygon": writer.AddPolygon(page, points, new AnnotationStyle([0, 0, 1], Fill: [1, 0.8, 0.8])); break;
            case "cloud": writer.AddCloud(page, [(100, 600), (200, 600), (200, 700), (100, 700)]); break;
            case "ink": writer.AddInk(page, [[(100, 600), (110, 620), (130, 625), (150, 610), (170, 640)], [(300, 600)]], new AnnotationStyle([0, 0, 0], 3, Opacity: 0.4)); break;
            case "freetext":
                writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "Hello, World (café)", new FreeTextStyle("Times New Roman", 14, FontStyles.Bold, [0, 0, 1], 1),
                    new AnnotationStyle([1, 0, 0], 2, Fill: [1, 1, 0.8]), Info);
                break;
            case "freetext-wrap":
                writer.AddFreeText(page, new PdfRect(100, 500, 220, 600), "The quick brown fox jumps over the lazy dog and keeps running\nSupercalifragilisticexpialidocious end", new FreeTextStyle(Size: 12));
                break;
            case "freetext-rich":
                writer.AddFreeText(page, new PdfRect(100, 600, 400, 660), "", new FreeTextStyle(RichText:
                    "<body xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font-size:12pt;font-family:Helvetica\"><p>plain <span style=\"font-weight:bold;color:#FF0000\">loud</span> <i>slanted</i> <u>under</u></p><p>second<br/>third</p></body>"));
                break;
            case "freetext-callout":
                writer.AddFreeText(page, new PdfRect(300, 600, 400, 640), "see here", null, new AnnotationStyle([0, 0, 0], 1), null, [(100, 500), (200, 500), (300, 620)]);
                break;
            case "stamp": writer.AddStamp(page, new PdfRect(100, 600, 300, 660), "Approved", Info); break;
            case "stamp-custom": writer.AddStamp(page, new PdfRect(100, 600, 300, 660), "Review me", null, [0, 0.4, 0]); break;
            case "note": writer.AddNote(page, new PdfRect(100, 700, 120, 720), Info); break;
            case "note-comment": writer.AddNote(page, new PdfRect(100, 700, 120, 720), Info, "Comment", [1, 0.5, 0]); break;
            case "caret": writer.AddCaret(page, new PdfRect(100, 600, 116, 616), Info); break;
            case "attachments":
                foreach (string icon in new[] { "PushPin", "Paperclip", "Graph", "Tag" })
                {
                    writer.AddFileAttachment(page, new PdfRect(100, 700, 116, 716), icon + ".txt", Encoding.ASCII.GetBytes("data of " + icon), Info, icon, "text/plain");
                }
                break;
            case "redact": writer.AddRedact(page, quads, Info, [0, 0, 0], "REDACTED"); break;
            case "link":
                writer.AddLink(page, new PdfRect(100, 600, 200, 620), new UriAction("https://example.com"), new AnnotationStyle([0, 0, 1], 2));
                writer.AddLink(page, new PdfRect(100, 500, 200, 520), new PdfDestination(0, DestinationFit.Fit));
                break;
            default: return [$"unknown appearance {name}"];
        }
        Fix(document);
        return Lines(Dump(document, 4));
    }

    private static IEnumerable<string> Edit()
    {
        var document = AnnotationFixtures.Blank(1);
        var writer = new PdfAnnotationWriter(document);
        var page = document.Pages[0];
        var ink = writer.Move(writer.AddInk(page, [[(100, 600), (120, 640)], [(200, 600), (220, 640)]]), 30, -10);
        var polygon = writer.AddPolygon(page, [(100, 600), (200, 600), (150, 700)], new AnnotationStyle(Width: 2));
        writer.Resize(polygon, new PdfRect(polygon.Rect.Left, polygon.Rect.Bottom, polygon.Rect.Left + polygon.Rect.Width * 2, polygon.Rect.Bottom + polygon.Rect.Height / 2));
        var highlight = writer.AddTextMarkup(page, AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(100, 500, 300, 514))]);
        writer.SetOpacity(writer.SetColor(highlight, [0, 1, 0]), 0.25);
        var note = writer.AddNote(page, new PdfRect(10, 700, 30, 720), new AnnotationInfo("A", "first"));
        writer.SetContents(note, "second", Day);
        var box = writer.AddFreeText(page, new PdfRect(100, 600, 300, 640), "styled");
        writer.SetFreeTextStyle(box, new FreeTextStyle("Courier New", 20, FontStyles.Bold, [1, 0, 0], 1));
        var gone = writer.AddSquare(page, new PdfRect(1, 1, 50, 50));
        writer.Delete(gone);
        Fix(document);
        return Lines(Dump(document, 4)).Append("ink " + Numbers(ink.InkList[0]) + " " + ink.Rect.ToArray());
    }

    // A hand-written file with threads, states, dates and a rich text only comment.
    private static PdfDocument Threads() => AnnotationFixtures.Blank(2, pdf =>
    {
        pdf.Obj(20, "<</Subtype /Text /Rect [10 700 30 720] /T (Zed) /Contents (parent) /M (D:20260301090000Z) /NM (n20)>>");
        pdf.Obj(21, "<</Subtype /Highlight /Rect [10 600 100 620] /T (alice) /Contents (marked) /M (D:20260301080000Z) /NM (n21)>>");
        pdf.Obj(22, "<</Subtype /Text /Rect [10 700 30 720] /IRT 20 0 R /RT /R /T (bob) /Contents (reply) /StateModel (Review) /State (Accepted) /M (D:20260301100000Z)>>");
        pdf.Obj(23, "<</Subtype /Text /Rect [10 700 30 720] /IRT 22 0 R /T (Carl) /Contents (second) /StateModel (Review) /State (Rejected) /M (D:20260301110000Z)>>");
        pdf.Obj(24, "<</Subtype /Square /Rect [10 10 80 80] /T (Alice) /Contents (box)>>");
        pdf.Obj(25, "<</Subtype /FreeText /Rect [100 100 200 200] /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one</p><p>two</p></body>) /M (D:20260301070000Z)>>");
        pdf.Obj(26, "<</Subtype /Link /Rect [0 0 5 5]>>");
        pdf.Obj(27, "<</Subtype /Text /Rect [200 700 220 720] /IRT 99 0 R /Contents (orphan) /T (ali)>>");
    }, "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 26 0 R 27 0 R]");

    private static IEnumerable<string> Comments()
    {
        var document = Threads();
        var results = new List<string>();
        string One(PdfComment c) => $"{Show(c.Text ?? "-")}|{Show(c.Author ?? "-")}|{c.PageIndex}|{c.Status}|{c.Replies.Count}|{Iso(c.Date)}";
        foreach (var order in new[] { CommentOrder.Page, CommentOrder.Date, CommentOrder.Author, CommentOrder.Type })
        {
            results.Add($"{order} " + string.Join(" ; ", PdfComments.List(document, null, order).Select(One)));
            results.Add($"{order} descending " + string.Join(" ; ", PdfComments.List(document, null, order, true).Select(One)));
        }
        results.Add("author ali " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(Author: "ALI")).Select(One)));
        results.Add("text SECOND " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(Text: "SECOND")).Select(One)));
        results.Add("rejected " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(Status: ReviewStatus.Rejected)).Select(One)));
        results.Add("replies " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(HasReplies: true)).Select(One)));
        results.Add("page 1 " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(PageIndex: 1)).Select(One)));
        results.Add("types " + string.Join(" ; ", PdfComments.List(document, new CommentFilter(Types: [AnnotationType.Square, AnnotationType.FreeText])).Select(One)));

        var parent = PdfAnnotations.Read(document, document.Pages[0]).First(a => a.Name == "n20");
        var reply = PdfComments.Reply(document, parent, "agreed", "Can", Day);
        var status = PdfComments.SetStatus(document, parent, ReviewStatus.Marked, "Deniz", Day.AddHours(1));
        Fix(document);
        results.Add("reply " + reply.Dictionary);
        results.Add("status " + status.Dictionary);
        results.Add("after " + string.Join(" ; ", PdfComments.List(document).Select(One)));
        return results;
    }

    private static PdfDocument Appearances(Action<TestPdf>? more = null, string rotate = "") => AnnotationFixtures.Blank(1, pdf =>
    {
        pdf.Stream(4, "", "0.5 0 0 0.5 0 0 cm 1 0 0 rg q BT /F1 20 Tf 100 100 Td (Page) Tj ET");
        pdf.Stream(30, "/Subtype /Form /BBox [0 0 50 50]", "0 0 50 50 re f");
        pdf.Stream(31, "/Subtype /Form /BBox [0 0 10 20] /Matrix [0 1 -1 0 0 0]", "0 0 10 20 re f");
        pdf.Stream(32, "/BBox [0 0 20 20]", "0 0 20 20 re f");
        pdf.Obj(40, "<</Subtype /Square /Rect [10 10 60 60] /NM (a) /AP <</N 30 0 R>>>>");
        pdf.Obj(41, "<</Subtype /Stamp /Rect [100 100 300 150] /NM (b) /AP <</N 31 0 R>> /F 4>>");
        pdf.Obj(42, "<</Subtype /Text /Rect [200 200 220 220] /NM (c) /AP <</N 32 0 R>> /F 20 /Popup 43 0 R>>");
        pdf.Obj(43, "<</Subtype /Popup /Rect [230 200 330 300] /Parent 42 0 R>>");
        pdf.Obj(44, "<</Subtype /Text /Rect [200 200 220 220] /IRT 42 0 R /NM (d) /AP <</N 32 0 R>>>>");
        pdf.Obj(45, "<</Subtype /Widget /Rect [300 300 320 320] /AS /On /AP <</N <</On 32 0 R /Off 30 0 R>>>>>>");
        pdf.Obj(46, "<</Subtype /Link /Rect [0 0 5 5] /AP <</N 30 0 R>>>>");
        pdf.Obj(47, "<</Subtype /Square /Rect [0 0 50 50] /F 2 /AP <</N 30 0 R>>>>");
        pdf.Obj(48, "<</Subtype /Square /Rect [0 0 50 50]>>");
        pdf.Obj(49, "<</Subtype /Square /Rect [70 70 90 90] /AP <</N 30 0 R>> /OC 50 0 R>>");
        pdf.Obj(50, "<</Type /OCG /Name (hidden)>>");
        more?.Invoke(pdf);
    }, "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R 47 0 R 48 0 R 49 0 R] /Contents 4 0 R " + rotate);

    private static IEnumerable<string> Flatten(string rest)
    {
        var document = Appearances(null, rest == "rotated" ? "/Rotate 90" : "");
        var results = new List<string>();
        if (rest == "widgets") results.Add("count " + PdfAnnotationFlattener.Flatten(document, document.Pages[0], new HashSet<AnnotationType> { AnnotationType.Widget }));
        else if (rest == "links") results.Add("count " + PdfAnnotationFlattener.Flatten(document, document.Pages[0], new HashSet<AnnotationType> { AnnotationType.Link, AnnotationType.Square }));
        else results.Add("count " + PdfAnnotationFlattener.FlattenAll(document));
        results.AddRange(Lines(Dump(document, 3)));
        return results;
    }

    // A file with a thread, a popup, an appearance stream and a rich text box, written by hand so that nothing in it is random.
    private static PdfDocument Marked() => AnnotationFixtures.Blank(2, pdf =>
    {
        pdf.Stream(30, "/Type /XObject /Subtype /Form /BBox [0 0 200 60] /Resources <</Font <</F1 31 0 R>>>>", "BT /F1 12 Tf 5 5 Td (Approved) Tj ET");
        pdf.Obj(31, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(20, "<</Type /Annot /Subtype /Text /Rect [50 100 70 120] /Contents <FEFF015F0069> /T (Ay\\351e) /Subj (Review) /NM (note) /M (D:20260301090000Z) /CreationDate (D:20260301090000Z) /C [1 0.5 0] /F 28 /Name /Comment /Popup 21 0 R /P 3 0 R /StructParent 4>>");
        pdf.Obj(21, "<</Type /Annot /Subtype /Popup /Rect [80 100 180 160] /Parent 20 0 R /Open true /NM (popup)>>");
        pdf.Obj(22, "<</Type /Annot /Subtype /Text /Rect [50 100 70 120] /IRT 20 0 R /RT /R /Contents (reply) /T (Can) /NM (reply) /StateModel (Review) /State (Accepted) /F 30>>");
        pdf.Obj(23, "<</Type /Annot /Subtype /Stamp /Rect [300 600 500 660] /Name /Approved /NM (stamp) /AP <</N 30 0 R>> /Dummy (x)>>");
        pdf.Obj(24, "<</Type /Annot /Subtype /Highlight /Rect [50 700 150 714] /QuadPoints [50 714 150 714 50 700 150 700] /C [1 1 0] /CA 0.5 /NM (hl) /BS <</W 2 /S /D /D [3 1]>>>>");
        pdf.Obj(25, "<</Type /Annot /Subtype /FreeText /Rect [100 100 300 140] /Contents (box) /DA (/Helv 12 Tf 0 g) /DS (font: Helvetica 12pt) /Q 1 /NM (ft) /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one &amp; <b>two</b></p></body>) /IC [1 1 0.8] /C [1 0 0] /RD [1 2 3 4] /LE [/Circle /ClosedArrow] /CL [1 2 3 4]>>");
        pdf.Obj(26, "<</Type /Annot /Subtype /Line /Rect [10 10 110 60] /L [10 10 110 60] /LE [/Circle /ClosedArrow] /NM (ln) /BS <</W 2>> /IT /LineArrow>>");
        pdf.Obj(27, "<</Type /Annot /Subtype /Ink /Rect [0 0 40 40] /InkList [[1 2 3 4] [5 6 7 8]] /NM (ink) /Open false>>");
        pdf.Obj(28, "<</Type /Annot /Subtype /Circle /Rect [0 0 40 40] /BE <</S /C /I 2>> /NM (ci) /Vertices [1 2 3 4]>>");
        pdf.Obj(29, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5]>>");
        pdf.Obj(32, "<</Type /Annot /Subtype /Square /Rect [5 5 25 25] /NM (sq) /Q 7 /RT /Group /Sy /P /IT /Foo>>");
    }, "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 29 0 R]").Also(d =>
    {
        d.Pages[1].Dictionary["Annots"] = new PdfArray([new PdfReference(25, 0), new PdfReference(26, 0), new PdfReference(27, 0), new PdfReference(28, 0), new PdfReference(32, 0)]);
    });

    private static T Also<T>(this T value, Action<T> action)
    {
        action(value);
        return value;
    }


    private static IEnumerable<string> Export()
    {
        var document = Marked();
        var fdf = PdfFdf.Export(document, "book.pdf");
        var results = new List<string>();
        foreach (var a in fdf.Annotations) results.Add($"annotation page={a.PageIndex} {a.Dictionary}");
        byte[] bytes = PdfFdf.Write(fdf);
        results.AddRange(ShowLines(Encoding.Latin1.GetString(bytes)));
        results.Add("narrow " + string.Join(",", PdfFdf.Export(document, null, new HashSet<AnnotationType> { AnnotationType.Highlight, AnnotationType.Stamp }).Annotations.Select(a => (a.Dictionary["Subtype"] as PdfName)!.Value)));

        var target = AnnotationFixtures.Blank(2);
        var result = PdfFdf.Import(target, PdfFdf.Read(bytes));
        results.Add($"import {result.Imported} {result.Skipped} {result.WithoutAppearance}");
        results.AddRange(Lines(Dump(target, 4)));
        var again = PdfFdf.Import(target, PdfFdf.Read(bytes));
        results.Add($"again {again.Imported} {again.Skipped} {again.WithoutAppearance}");
        string xml = Encoding.UTF8.GetString(PdfXfdf.Write(fdf)).Replace("\r\n", "\n");
        results.AddRange(ShowLines(xml));
        var xfdf = PdfXfdf.Read(xml);
        results.Add($"xfdf {xfdf.Annotations.Count} {xfdf.FileName}");
        foreach (var a in xfdf.Annotations) results.Add($"xannotation page={a.PageIndex} {Fold(a.Dictionary)}");
        var target2 = AnnotationFixtures.Blank(2);
        var result2 = PdfFdf.Import(target2, xfdf);
        results.Add($"ximport {result2.Imported} {result2.Skipped} {result2.WithoutAppearance}");
        results.AddRange(Lines(Dump(target2, 4)));
        return results;
    }

    // An FDF file read, shown, written again and turned into XFDF.
    private static IEnumerable<string> Fdf(byte[] bytes)
    {
        var fdf = PdfFdf.Read(bytes);
        var results = new List<string> { $"file {Show(fdf.FileName ?? "-")}" };
        foreach (var f in fdf.FlatFields()) results.Add($"field {Show(f.Key)} {f.Value}");
        foreach (var a in fdf.Annotations) results.Add($"annotation page={a.PageIndex} {a.Dictionary}");
        byte[] written = PdfFdf.Write(fdf);
        results.AddRange(ShowLines(Encoding.Latin1.GetString(written)));
        results.AddRange(ShowLines(Encoding.UTF8.GetString(PdfXfdf.Write(fdf)).Replace("\r\n", "\n")));
        return results;
    }

    // An XFDF file read, shown and written again.
    private static IEnumerable<string> Xfdf(byte[] bytes)
    {
        var fdf = PdfXfdf.Read(bytes);
        var results = new List<string> { $"file {Show(fdf.FileName ?? "-")}" };
        foreach (var f in fdf.FlatFields()) results.Add($"field {Show(f.Key)} {f.Value}");
        foreach (var a in fdf.Annotations) results.Add($"annotation page={a.PageIndex} {Fold(a.Dictionary)}");
        string xml = Encoding.UTF8.GetString(PdfXfdf.Write(fdf)).Replace("\r\n", "\n");
        results.AddRange(ShowLines(xml));
        return results;
    }

    private static IEnumerable<string> Attach()
    {
        var document = StructureFixtures.Open(2);
        var made = new DateTimeOffset(2026, 5, 6, 7, 8, 9, TimeSpan.FromHours(2));
        var results = new List<string>();
        PdfAttachments.Add(document, "notes.txt", Encoding.ASCII.GetBytes("short notes"), "text/plain", "Meeting notes", made, made.AddDays(1));
        PdfAttachments.Add(document, "notes.txt", [1, 2, 3]);
        PdfAttachments.Add(document, "dir/a.b.txt", [4]);
        PdfAttachments.Add(document, "dir/a.b.txt", [5]);
        PdfAttachments.Add(document, ".hidden", [6]);
        PdfAttachments.Add(document, ".hidden", [7]);
        PdfAttachments.Add(document, "end.", [8]);
        PdfAttachments.Add(document, "end.", [9]);
        PdfAttachments.Add(document, "Invoice: March.pdf", [10]);
        PdfAttachments.Add(document, "Invoice: March.pdf", [11]);
        PdfAttachments.Add(document, "a.b:c", [12]);
        PdfAttachments.Add(document, "a.b:c", [13]);
        foreach (var a in PdfAttachments.List(document)) results.Add($"item {Show(a.Name)}|{Show(a.FileName)}|{Show(a.Description ?? "-")}|{a.MimeType ?? "-"}|{a.Size}|{a.StoredSize}|{Iso(a.Created)}|{Iso(a.Modified)}|{a.CheckSum}|{a.PageIndex}");
        results.AddRange(Lines(Dump(document, 3)));
        var list = PdfAttachments.List(document);
        PdfAttachments.Remove(document, list[1]);
        results.Add("removed " + string.Join(",", PdfAttachments.List(document).Select(a => Show(a.Name))));
        foreach (var a in PdfAttachments.List(document).ToList()) PdfAttachments.Remove(document, a);
        results.Add("empty " + document.Catalog);
        return results;
    }

    private static IEnumerable<string> Layers()
    {
        var document = StructureFixtures.File("/OCProperties <</OCGs [30 0 R 31 0 R 32 0 R 33 0 R] /D <</BaseState /OFF /ON [30 0 R] /Locked [32 0 R] /RBGroups [[30 0 R 31 0 R 33 0 R]] /Order [30 0 R (Group) [31 0 R 32 0 R]]>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (Background) /Intent /View>>");
            pdf.Obj(31, "<</Type /OCG /Name <FEFF0416> /Intent [/Design /View]>>");
            pdf.Obj(32, "<</Type /OCG>>");
            pdf.Obj(33, "<</Type /OCG /Name (Extra)>>");
        });
        var results = new List<string>();
        void Report(string title)
        {
            var set = PdfLayers.Read(document);
            results.Add(title + " " + string.Join(",", set.Layers.Select(l => $"{Show(l.Name)}:{(l.IsOn ? "on" : "off")}:{(l.Locked ? "locked" : "-")}:{l.Intent ?? "-"}")));
            results.Add("order " + string.Join(",", Order(set.Order)));
        }
        Report("read");
        results.Add("set " + PdfLayers.SetVisible(document, new PdfReference(31, 0), true));
        Report("31 on");
        results.Add("set " + PdfLayers.SetVisible(document, new PdfReference(30, 0), true));
        Report("30 on");
        results.Add("set " + PdfLayers.SetVisible(document, new PdfReference(33, 0), false));
        Report("33 off");
        results.Add("set " + PdfLayers.SetVisible(document, new PdfReference(99, 0), false));
        results.Add(document.Dict(document.Catalog, "OCProperties")!.ToString());
        return results;
    }

    private static IEnumerable<string> Order(IEnumerable<LayerNode> nodes) =>
        nodes.Select(n => (n.Label is { } l ? "'" + Show(l) + "'" : "") + (n.Layer is { } layer ? Show(layer.Name) : "") + (n.Children.Count > 0 ? "(" + string.Join(",", Order(n.Children)) + ")" : ""));

    private static IEnumerable<string> Facts(string name)
    {
        var document = name switch
        {
            "everything" => StructureFixtures.File(
                "/Lang (en) /MarkInfo <</Marked true>> /OpenAction 30 0 R /Outlines 31 0 R /Collection <</View /T>> /AcroForm <</Fields [32 0 R] /SigFlags 3>> " +
                "/OCProperties <</OCGs [33 0 R 34 0 R]>> /Names <</EmbeddedFiles <</Names [(a) 35 0 R]>>>>",
                pdf =>
                {
                    pdf.Obj(30, "<</S /JavaScript /JS (1)>>");
                    pdf.Obj(31, "<</First 36 0 R /Last 36 0 R /Count 1>>");
                    pdf.Obj(32, "<</FT /Tx /T (f)>>");
                    pdf.Obj(33, "<</Type /OCG /Name (a)>>");
                    pdf.Obj(34, "<</Type /OCG /Name (b)>>");
                    pdf.Stream(37, "", "x");
                    pdf.Obj(35, "<</F (a.txt) /EF <</F 37 0 R>>>>");
                    pdf.Obj(36, "<</Title (t)>>");
                }),
            "xfa" => StructureFixtures.File("/AcroForm <</Fields [] /XFA [(template) 30 0 R]>>", pdf => pdf.Stream(30, "", "<x/>")),
            "rotated" => StructureFixtures.File("", null, 2, "/Rotate 90 /UserUnit 2"),
            _ => StructureFixtures.Open(3),
        };
        var f = DocumentFacts.Read(document);
        return
        [
            $"{f.Version} {f.FileSize} {f.PageCount} {N(f.FirstPageWidth)} {N(f.FirstPageHeight)} lang={f.Language ?? "-"} tagged={f.IsTagged} linearized={f.IsLinearized} encrypted={f.IsEncrypted} signed={f.IsSigned} certified={f.IsCertified}",
            $"{f.Form} js={f.HasJavaScript} bookmarks={f.HasBookmarks} portfolio={f.IsPortfolio} attachments={f.AttachmentCount} layers={f.LayerCount} pdfa={f.PdfAPart?.ToString() ?? "-"}/{f.PdfAConformance ?? "-"} repairs={f.RepairCount} title={f.Metadata.Title ?? "-"}",
            "text " + Show(StructureText.FormKindName(f.Form)) + " " + Show(StructureText.UnnamedLayer) + " " + Show(StructureText.NewBookmark),
        ];
    }
}
