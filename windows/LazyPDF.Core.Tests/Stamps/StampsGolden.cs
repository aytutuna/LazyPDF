using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Stamps/StampsGolden.swift. One line of input is "<op> <words>" (the format is at the top of
// stamps-input.txt): Bates numbers, date formats, header and footer tokens, JPEG headers, and whole stamped documents. A
// document is shown as every object of the file, streams decoded (a JPEG only by its length), because the deflate of the two
// sides is not the same one; what the stamper reports and lists comes first.
internal static class StampsGolden
{
    private static readonly DateTimeOffset Day = new DateTimeOffset(2026, 3, 9, 14, 5, 7, TimeSpan.FromHours(3)).AddTicks(1234567);

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
            foreach (string result in Op(op, Encoding.UTF8.GetString(Golden.Unescape(rest)))) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        switch (op)
        {
            case "bates": return [Bates(rest)];
            case "date": return [DateOp(rest)];
            case "expand": return [Show(StampTokens.Expand(rest, Values()))];
            case "jpeg": return [Jpeg(rest)];
            case "stamp": return Stamp(rest);
            default: return [$"unknown op {op}"];
        }
    }

    // prefix|suffix|digits|number
    private static string Bates(string rest)
    {
        string[] p = rest.Split('|');
        return Show(new BatesSpec(p[0], p[1], int.Parse(p[2], CultureInfo.InvariantCulture)).Format(long.Parse(p[3], CultureInfo.InvariantCulture)));
    }

    // culture|format: the fixed day, formatted by .NET.
    private static string DateOp(string rest)
    {
        int bar = rest.IndexOf('|');
        try
        {
            return Show(Day.ToString(rest[(bar + 1)..], new CultureInfo(rest[..bar])));
        }
        catch (FormatException)
        {
            return "format error";
        }
    }

    private static StampTokens.Values Values() => new(7, 20, "B-000007", new HeaderFooterSpec { Date = Day, FileName = "report.pdf", Bates = new BatesSpec() });

    private static string Jpeg(string hex)
    {
        var bytes = Convert.FromHexString(hex);
        return PdfImageWriter.TryReadJpegHeader(bytes, out int width, out int height, out int components) ? $"{width} {height} {components}" : "none";
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

    private static string Dump(PdfDocument document)
    {
        var sb = new StringBuilder();
        foreach (int number in document.ObjectNumbers)
        {
            string text = document.Get(number) switch
            {
                PdfStream s when s.Dictionary["Filter"] is PdfName { Value: "DCTDecode" } => $"stream {s.Dictionary} | jpeg {s.Data!.Length}",
                PdfStream s => $"stream {s.Dictionary} | {Show(Encoding.Latin1.GetString(document.Data(s)))}",
                null => "null",
                var value => value.ToString()!,
            };
            sb.Append(number).Append(": ").Append(text).Append('\n');
        }
        return sb.ToString().TrimEnd('\n');
    }

    private static string Report(StampRun run) => $"run {run.Id} {run.Pages} {run.NextBates} [{string.Join(",", run.Missing)}]";

    private static IEnumerable<string> List(PdfStamper stamper) =>
        stamper.List().Select(i => $"info {i.Id} {i.Kind} {(i.Label is null ? "-" : Show(i.Label))} {i.Behind} [{string.Join(",", i.Pages)}]");

    private static IEnumerable<string> Stamp(string name)
    {
        var jpeg = Convert.FromBase64String(StampKit.SampleJpeg);
        var lines = new List<string>();
        PdfDocument document;
        PdfStamper stamper;
        switch (name)
        {
            case "wm-text":
                document = StampKit.Doc(2);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "CONFIDENTIAL" })));
                break;
            case "wm-lines":
                document = StampKit.Doc(1);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec
                {
                    Text = "LONGER LINE\r\nAB\fc",
                    Rotation = 30,
                    Anchor = StampAnchor.TopRight,
                    OffsetX = 5,
                    OffsetY = 7,
                    Color = new StampColor(1, 0, 0),
                    Scale = 0.4,
                    Opacity = 0.5,
                    FontStyle = FontStyles.Bold | FontStyles.Italic,
                })));
                break;
            case "wm-image":
                document = StampKit.Doc(1);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec
                {
                    Image = PdfImageWriter.AddJpeg(document, jpeg)!,
                    Scale = 0.5,
                    Rotation = -20,
                    Anchor = StampAnchor.BottomLeft,
                    Opacity = 0.6,
                })));
                break;
            case "wm-layer":
                document = StampKit.Doc(2);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "LAYER", LayerName = "Mark ç", Behind = true })));
                break;
            case "wm-pages":
                document = StampKit.Doc(4);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "SOME", Pages = [2, 0, 9, -1, 2], Anchor = StampAnchor.Bottom })));
                break;
            case "bg-color":
                document = StampKit.Doc(2);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Color = new StampColor(1, 1, 0.8) })));
                break;
            case "bg-fits":
                document = StampKit.Doc(3);
                stamper = new PdfStamper(document);
                var image = PdfImageWriter.AddJpeg(document, jpeg)!;
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Cover, Pages = [0] })));
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Contain, Pages = [1] })));
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Image = image, Fit = BackgroundFit.Stretch, Pages = [2] })));
                break;
            case "bg-both":
                document = StampKit.Doc(1);
                stamper = new PdfStamper(document);
                var pixels = PdfImageWriter.AddRgba(document, 2, 2, [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 9, 9, 9, 255]);
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.9), Image = pixels, Opacity = 0.5, LayerName = "Back" })));
                break;
            case "hf-basic":
                document = StampKit.Doc(2);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec
                {
                    Header = new("HL", "HC", "HR"),
                    Footer = new("FL", "FC", "FR"),
                    FontSize = 9,
                    FontStyle = FontStyles.Italic,
                    Color = StampColor.Gray(0.25),
                    MarginX = 30,
                    MarginTop = 20,
                    MarginBottom = 25,
                })));
                break;
            case "hf-tokens":
                document = StampKit.Doc(3);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec
                {
                    Header = new("{page}/{pages}", "{date} {date:dd MMMM yyyy}", "{date:bad'} {file}"),
                    Footer = new("{bates}", "{nope} {", "(x)\\y"),
                    StartNumber = 5,
                    Date = Day,
                    FileName = "report.pdf",
                    Bates = new BatesSpec("B-", ".x", 4, 41),
                    Culture = new CultureInfo("en-GB"),
                })));
                break;
            case "hf-evenodd":
                document = StampKit.Doc(4);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec
                {
                    Header = new("", "", "odd"),
                    EvenHeader = new("even", "", ""),
                    Footer = new("", "{page}", ""),
                    EvenFooter = new(),
                    Pages = [0, 1, 2],
                })));
                break;
            case "rotated":
                document = StampKit.Pages(
                    ("/Rotate 90", "BT /F1 12 Tf 50 50 Td (a) Tj ET"),
                    ("/Rotate 180", "BT /F1 12 Tf 50 50 Td (b) Tj ET"),
                    ("/UserUnit 2", "BT /F1 12 Tf 50 50 Td (c) Tj ET"),
                    ("/CropBox [10 20 110 220] /Rotate 270", "BT /F1 12 Tf 50 50 Td (d) Tj ET"));
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Color = StampColor.Gray(0.95) })));
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "SIDE", Rotation = 45 })));
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec { Header = new("", "AB", ""), Footer = new("CD", "", "{page}") })));
                break;
            case "unbalanced":
                document = StampKit.Pages(
                    ("", "q 2 0 0 2 10 10 cm 0 1 0 rg BT /F1 12 Tf 50 50 Td (a) Tj ET"),
                    ("", "BT /F1 12 Tf 50 50 Td (b) Tj ET Q Q Q"),
                    ("", "/Span BMC q BT /F1 12 Tf 50 50 Td (c) Tj"),
                    ("", "q q q q"));
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "S", Rotation = 20 })));
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec { Header = new("S", "", "") })));
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Color = StampColor.Black })));
                break;
            case "update-remove":
                document = StampKit.Doc(3);
                stamper = new PdfStamper(document);
                var first = stamper.AddWatermark(new WatermarkSpec { Text = "OLD", Opacity = 0.2, LayerName = "L" });
                lines.Add(Report(first));
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec { Footer = new("", "{page}", "") })));
                lines.Add(Report(stamper.AddBackground(new BackgroundSpec { Color = StampColor.Black, Pages = [0, 2] })));
                lines.Add(Report(stamper.Update(first.Id, new WatermarkSpec { Text = "NEW", Opacity = 0.8, Pages = [1] })));
                lines.AddRange(List(stamper));
                lines.Add("removed " + stamper.Remove(2));
                lines.Add("removed again " + stamper.Remove(2));
                break;
            case "remove-all":
                document = StampKit.Doc(2);
                stamper = new PdfStamper(document);
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "A", LayerName = "One" })));
                lines.Add(Report(stamper.AddWatermark(new WatermarkSpec { Text = "B", LayerName = "Two", Behind = true })));
                lines.Add(Report(stamper.AddHeaderFooter(new HeaderFooterSpec { Header = new("h", "", "") })));
                lines.Add("removed " + stamper.RemoveAll());
                break;
            default:
                return [$"unknown stamp {name}"];
        }
        lines.AddRange(List(stamper));
        lines.AddRange(Dump(document).Split('\n'));
        return lines;
    }
}
