using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Updates written by hand: object streams, cross-reference streams and tables the writer would never make.</summary>
internal static class SignatureRawKit
{
    public const string Evil = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET";
    public const string Form = "/Type /XObject /Subtype /Form /BBox [0 0 300 400]";

    public static string StreamBody(string data, string extra = "") => $"<<{extra} /Length {data.Length}>>\nstream\n{data}\nendstream";

    public static bool ShowsEvil(byte[] file) => Encoding.Latin1.GetString(PdfDocument.Open(file).Pages[0].Contents()).Contains("pay 1,000,000");

    /// <summary>What a trailer of an update repeats from the file it follows: the catalog, and the information and identity when there are any.</summary>
    public static string Kept(PdfDocument document) => $" /Root {document.Trailer["Root"]}" + Identity(document);

    public static string Identity(PdfDocument document) =>
        string.Concat(new[] { "Info", "ID", "Encrypt" }.Where(key => document.Trailer[key] is not null).Select(key => $" /{key} {document.Trailer[key]}"));

    public static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    /// <summary>The first signature reads as changed and the reason is that the update's bytes cannot be placed exactly.</summary>
    public static void AssertUnreadable(byte[] file)
    {
        var report = Check(file);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }

    /// <summary>The strict reader accepts what follows the first signature's bytes: the same bytes with the update's body judged by the rules.</summary>
    public static bool PassesGate(byte[] file)
    {
        var found = SignatureScan.Find(file).OrderBy(f => f.Offset).First();
        var ranges = (PdfArray)found.Dictionary["ByteRange"]!;
        int end = (int)((PdfNumber)ranges.Items[2]).Value + (int)((PdfNumber)ranges.Items[3]).Value;
        return UpdateGate.Check(PdfDocument.Open(file.AsSpan(0, end).ToArray()), PdfDocument.Open(file)) is not null;
    }

    /// <summary>
    /// An update of <paramref name="objects"/> with a table, whose trailer repeats what the file's does and adds
    /// <paramref name="extra"/>; <paramref name="size"/> is /Size when the right one is not wanted.
    /// </summary>
    public static byte[] Append(byte[] file, string extra, long? size, params (int Number, string Body)[] objects)
    {
        var document = PdfDocument.Open(file);
        var text = new StringBuilder("\n");
        var offsets = new List<(int, long)>();
        foreach (var (number, body) in objects)
        {
            offsets.Add((number, file.Length + text.Length));
            text.Append($"{number} 0 obj\n{body}\nendobj\n");
        }
        long xref = file.Length + text.Length;
        text.Append("xref\n0 1\n0000000000 65535 f \n");
        foreach (var (number, offset) in offsets.OrderBy(o => o.Item1)) text.Append($"{number} 1\n{offset:D10} 00000 n \n");
        long highest = objects.Length == 0 ? 0 : objects.Max(o => o.Number);
        text.Append($"trailer\n<</Size {size ?? Math.Max(document.NextObjectNumber, highest + 1)}{Kept(document)} /Prev {document.StartXref}{extra}>>\nstartxref\n{xref}\n%%EOF\n");
        return [.. file, .. TestPdf.Latin(text.ToString())];
    }

    // A cross-reference stream entry of widths 1, 4 and 2.
    private static string Entry(int type, long second, int third) =>
        new([(char)type, (char)(second >> 24 & 255), (char)(second >> 16 & 255), (char)(second >> 8 & 255), (char)(second & 255), (char)(third >> 8 & 255), (char)(third & 255)]);

    /// <summary>
    /// An update with <paramref name="plain"/> objects, an object stream 40 holding <paramref name="data"/> that lists
    /// object <paramref name="member"/> as its entry number <paramref name="index"/>, and a cross-reference stream 41.
    /// </summary>
    public static byte[] WithObjectStream(byte[] signed, string data, int count, int first, int member, int index, params (int Number, string Body)[] plain)
    {
        var document = PdfDocument.Open(signed);
        var text = new StringBuilder("\n");
        var entries = new SortedDictionary<int, string>();
        foreach (var (number, body) in plain)
        {
            entries[number] = Entry(1, signed.Length + text.Length, 0);
            text.Append($"{number} 0 obj\n{body}\nendobj\n");
        }
        entries[member] = Entry(2, 40, index);
        entries[40] = Entry(1, signed.Length + text.Length, 0);
        text.Append($"40 0 obj\n<</Type /ObjStm /N {count} /First {first} /Length {data.Length}>>\nstream\n{data}\nendstream\nendobj\n");
        long table = signed.Length + text.Length;
        entries[41] = Entry(1, table, 0);
        string rows = string.Concat(entries.Values);
        string ranges = string.Join(" ", entries.Keys.Select(k => $"{k} 1"));
        text.Append($"41 0 obj\n<</Type /XRef /Size {Math.Max(document.NextObjectNumber, entries.Keys.Max() + 1)} /W [1 4 2] /Index [{ranges}] {Kept(document)} /Prev {document.StartXref} /Length {rows.Length}>>\nstream\n{rows}\nendstream\nendobj\nstartxref\n{table}\n%%EOF\n");
        return [.. signed, .. TestPdf.Latin(text.ToString())];
    }
}
