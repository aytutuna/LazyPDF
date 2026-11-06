using System.Globalization;
using System.IO.Compression;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Export/ExportGolden.swift. One line of input is "<op> <words>" (the format is at the top
// of export-input.txt): pages analysed into the model the writers share, the writers' text, the parts of the Office packages,
// the PNG rows, the numbers of a sheet and what a JPEG header says. A package is shown by the name, size and CRC-32 of each
// part as it reads back, because the deflate of the two sides is not the same one. Numbers go through PdfNumber, which both
// sides write alike; text goes through Esc, which writes every UTF-16 unit outside printable ASCII as \uXXXX.
internal static class ExportGolden
{
    public static string Run(string input)
    {
        // An empty table stands in for the translations, so that every machine writes the English text.
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
                output.Append("> ").Append(line.Length > 160 ? line[..160] + "..." : line).Append('\n');
                foreach (string result in Op(op, rest)) output.Append("< ").Append(result).Append('\n');
            }
            return output.ToString();
        }
        finally
        {
            Loc.Table = null;
        }
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        try
        {
            switch (op)
            {
                case "layout": return Writer("model", ExportLayout.Analyze(ExportKit.Open(Content(rest))));
                case "content":
                    {
                        int space = rest.IndexOf(' ');
                        return Writer(rest[..space], ExportLayout.Analyze(ExportKit.Open(Content(rest[(space + 1)..]))));
                    }
                case "report": return Writer(rest, ExportLayout.Analyze(ExportKit.Report()));
                case "built":
                    {
                        int space = rest.IndexOf(' ');
                        return Writer(rest[(space + 1)..], Built(rest[..space]));
                    }
                case "number": return Number(Text(rest));
                case "jpeg": return Jpeg(Convert.FromHexString(rest));
                case "place": return Place(rest);
                case "png": return Png(rest);
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    private static string Content(string rest) => Encoding.Latin1.GetString(Golden.Unescape(rest));

    private static string Text(string rest) => Encoding.UTF8.GetString(Golden.Unescape(rest));

    private static string N(double v) => new PdfNumber(v).Text;

    private static string B(bool value) => value ? "1" : "0";

    private static string Box(DisplayRect r) => $"[{N(r.X)} {N(r.Y)} {N(r.Width)} {N(r.Height)}]";

    private static string Esc(string text)
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
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("X4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static IEnumerable<string> Writer(string writer, ExportDocument model)
    {
        switch (writer)
        {
            case "model": return Model(model);
            case "plain": return [Esc(PlainTextWriter.Make(model))];
            case "markdown": return [Esc(MarkdownWriter.Make(model))];
            case "markdownembed": return [Esc(MarkdownWriter.Make(model, embedImages: true))];
            case "htmlreflowed": return [Esc(HtmlWriter.Reflowed(model))];
            case "htmlfixed": return [Esc(HtmlWriter.Fixed(model))];
            case "rtf": return [Esc(RtfWriter.Make(model))];
            case "docx": return Package(DocxWriter.Make(model));
            case "xlsx": return Package(XlsxWriter.Make(model));
            case "pptx": return Package(PptxWriter.Make(model));
            default: return [$"unknown writer {writer}"];
        }
    }

    private static IEnumerable<string> Model(ExportDocument d)
    {
        var lines = new List<string>
        {
            $"model title={(d.Title is null ? "-" : Esc(d.Title))} body={N(d.BodySize)} left={d.PicturesLeftOut} pages={d.Pages.Count}",
        };
        foreach (var page in d.Pages)
        {
            lines.Add($"page {page.Index} {N(page.Width)} {N(page.Height)} blocks={page.Blocks.Count} lines={page.Lines.Count} pictures={page.Pictures.Count}");
            foreach (var block in page.Blocks)
            {
                lines.Add(block switch
                {
                    ExportParagraph p => $"  paragraph heading={p.Heading} item={Item(p.Item)} {Box(p.Bounds)} runs={Runs(p.Runs)}",
                    ExportTable t => $"  table ruled={B(t.Ruled)} {t.Rows.Count}x{t.Columns} {Box(t.Bounds)} widths={(t.Widths is null ? "-" : string.Join(",", t.Widths.Select(N)))} cells={string.Join(";", t.Rows.Select(r => string.Join("|", r.Select(Esc))))}",
                    ExportPicture p => $"  picture {Image(p.Image)} {Box(p.Bounds)}",
                    _ => "  unknown block",
                });
            }
            foreach (var line in page.Lines) lines.Add($"  line {Box(line.Bounds)} runs={Runs(line.Runs)}");
        }
        return lines;
    }

    private static string Item(ExportListItem? item) => item is null ? "-" : $"{item.ListId},{B(item.Ordered)},{item.Level},{item.Number}";

    private static string Runs(IReadOnlyList<ExportRun> runs) =>
        string.Join(" ", runs.Select(r => $"<{Esc(r.Text)}:{B(r.Bold)}{B(r.Italic)}:{N(r.Size)}>"));

    // A PNG holds the deflate of the side that wrote it, so it is shown by its size and format only.
    private static string Image(ExportImage image) =>
        image.IsJpeg ? $"jpeg {image.Width}x{image.Height} bytes={image.Data.Length} crc={ExportZip.Crc32(image.Data):X8}" : $"png {image.Width}x{image.Height}";

    private static IEnumerable<string> Package(byte[] package)
    {
        using var zip = new ZipArchive(new MemoryStream(package), ZipArchiveMode.Read);
        foreach (var entry in zip.Entries)
        {
            using var stream = entry.Open();
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            yield return $"{entry.FullName} {copy.Length} {ExportZip.Crc32(copy.ToArray()):X8}";
        }
    }

    private static ExportDocument Built(string name)
    {
        ExportDocument Page(params ExportBlock[] blocks) => new("Başlık", [new ExportPage(0, 612, 792, blocks, [], [])], 11);
        ExportParagraph Entry(string text, int level, bool ordered, int number) =>
            new(new DisplayRect(72 + 18 * level, 72 + 20 * level, 100, 12), [new ExportRun(text, false, false, 11)], 0, new ExportListItem(3, ordered, level, number));
        switch (name)
        {
            case "turkish":
                return Page(
                    new ExportParagraph(new DisplayRect(72, 60, 300, 24), [new ExportRun("Başlık & <özet>", true, false, 18)], 2),
                    new ExportParagraph(new DisplayRect(72, 100, 400, 14),
                    [
                        new ExportRun("Çağrı ğ Ş ı İ ", false, false, 11),
                        new ExportRun("{x} \"q\" ", true, false, 11),
                        new ExportRun(" a\\b # * _ | [l] ", false, true, 11),
                        new ExportRun("tab\there", true, true, 11),
                    ]),
                    new ExportParagraph(new DisplayRect(72, 130, 400, 14), [new ExportRun("1. not a list", false, false, 11)]),
                    new ExportParagraph(new DisplayRect(72, 150, 400, 14), [new ExportRun("- not a bullet", false, false, 11)]));
            case "nested":
                return Page(Entry("a", 0, false, 0), Entry("b", 1, false, 0), Entry("c", 1, false, 0), Entry("d", 0, false, 0),
                    new ExportParagraph(new DisplayRect(72, 200, 100, 12), [new ExportRun("between", false, false, 11)]),
                    Entry("five", 0, true, 5), Entry("six", 0, true, 6), Entry("inner", 2, true, 1));
            case "special":
                return Page(new ExportParagraph(new DisplayRect(72, 72, 100, 12), [new ExportRun("a < b & c > \"d\" \u0001x\uFFFEy\tz\r\nw", false, false, 11)]));
            case "tables":
                return Page(
                    new ExportTable(new DisplayRect(72, 72, 300, 40), [["Name", "Qty", "Price"], ["Tea", "3", "4.50"], ["Coffee", "007", "1.234,56"], ["Milk\nsemi", "1e5", "-12"]], [100, 200, 50], true),
                    new ExportTable(new DisplayRect(72, 200, 300, 40), [[.. Enumerable.Range(0, 70).Select(i => "c" + i)], [.. Enumerable.Range(0, 70).Select(i => i.ToString())]], null, false));
            case "tiny":
                return new("t", [new ExportPage(0, 30, 40, [new ExportPicture(new DisplayRect(2, 2, 26, 36), new ExportImage(ExportKit.Jpeg, true, 8, 6))], [], [])], 11);
            case "pages":
                {
                    var jpeg = new ExportImage(ExportKit.Jpeg, true, 8, 6);
                    var one = new ExportPage(0, 100, 100, [new ExportPicture(new DisplayRect(5, 5, 20, 15), jpeg)],
                        [new ExportTextLine(new DisplayRect(10, 10, 50, 10), [new ExportRun("A", false, false, 10)])], [new ExportPicture(new DisplayRect(5, 5, 20, 15), jpeg)]);
                    var two = new ExportPage(1, 200, 200, [],
                        [new ExportTextLine(new DisplayRect(20, 20, 100, 20), [new ExportRun("B", false, true, 20), new ExportRun("\tc", true, false, 9.5)])],
                        [new ExportPicture(new DisplayRect(40, 40, 60, 45), jpeg)]);
                    return new(null, [one, two], 10);
                }
            default:
                return new(null, [], 11);
        }
    }

    // number <text>: what the sheet makes of a cell and how it writes the number down.
    private static IEnumerable<string> Number(string text)
    {
        if (!XlsxWriter.TryNumber(text, out double value)) return ["text"];
        return [$"number {value.ToString("R", CultureInfo.InvariantCulture)}"];
    }

    // jpeg <hex>: the density and the Exif orientation of the header.
    private static IEnumerable<string> Jpeg(byte[] file)
    {
        var (x, y) = JpegMeta.Density(file);
        return [$"density {N(x)} {N(y)} orientation {JpegMeta.Orientation(file)}"];
    }

    // place <orientation> <w> <h> <x> <y>: where the unit square of the picture goes.
    private static IEnumerable<string> Place(string rest)
    {
        string[] words = rest.Split(' ');
        double D(int i) => double.Parse(words[i], CultureInfo.InvariantCulture);
        var m = JpegMeta.Placement(int.Parse(words[0], CultureInfo.InvariantCulture), D(1), D(2), D(3), D(4));
        return [$"[{N(m.A)} {N(m.B)} {N(m.C)} {N(m.D)} {N(m.E)} {N(m.F)}]"];
    }

    // png <kind> <w> <h>: the format and the filtered rows of the PNG, as the deflate gives them back.
    private static IEnumerable<string> Png(string rest)
    {
        string[] words = rest.Split(' ');
        int w = int.Parse(words[1], CultureInfo.InvariantCulture), h = int.Parse(words[2], CultureInfo.InvariantCulture);
        var rgba = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int o = (y * w + x) * 4;
                (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = words[0] switch
                {
                    "gray" => ((byte)(x * 5 + y * 3), (byte)(x * 5 + y * 3), (byte)(x * 5 + y * 3), (byte)255),
                    "flat" => ((byte)200, (byte)200, (byte)200, (byte)255),
                    "alpha" => ((byte)(x * 7 + y), (byte)(y * 11), (byte)((x ^ y) * 13), (byte)(x * 255 / Math.Max(1, w - 1))),
                    _ => ((byte)(x * 7 + y), (byte)(y * 11), (byte)((x ^ y) * 13), (byte)255),
                };
            }
        }
        var png = PngWriter.Encode(new PdfRgbaImage(w, h, rgba));
        var idat = new MemoryStream();
        for (int pos = 8; pos < png.Length;)
        {
            int length = png[pos] << 24 | png[pos + 1] << 16 | png[pos + 2] << 8 | png[pos + 3];
            if (Encoding.ASCII.GetString(png, pos + 4, 4) == "IDAT") idat.Write(png, pos + 8, length);
            pos += 12 + length;
        }
        idat.Position = 0;
        using var raw = new MemoryStream();
        using (var z = new ZLibStream(idat, CompressionMode.Decompress)) z.CopyTo(raw);
        byte[] rows = raw.ToArray();
        int channels = png[25] switch { 0 => 1, 2 => 3, _ => 4 };
        string filters = string.Concat(Enumerable.Range(0, h).Select(y => rows[y * (w * channels + 1)].ToString(CultureInfo.InvariantCulture)));
        return [$"type={png[25]} filters={filters} raw={rows.Length} crc={ExportZip.Crc32(rows):X8}"];
    }
}
