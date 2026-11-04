using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Test files for the linearizer and a checker that reads the result the way a viewer would, from the bytes and the hint tables.</summary>
internal static class LinearizerKit
{
    private static int _kept;

    public static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    /// <summary>
    /// A file of <paramref name="count"/> pages: catalog 1 with bookmarks, a page tree 2 whose resources
    /// (4) every page inherits unless it has its own, a shared font 3 and form 6, an info 8, pages from 10,
    /// then their contents, then on odd pages a font of their own. Each page links to the next.
    /// </summary>
    public static byte[] Make(int count, string header = "%PDF-1.4\n")
    {
        var pdf = new TestPdf(header);
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 5 0 R /PageMode /UseOutlines>>");
        string kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{10 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 200 300] /Resources 4 0 R>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(4, "<</Font <</F1 3 0 R>> /XObject <</Fm 6 0 R>>>>");
        pdf.Obj(5, "<</Type /Outlines /First 7 0 R /Last 7 0 R /Count 1>>");
        pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 5 5 re f");
        pdf.Obj(7, $"<</Title (First) /Parent 5 0 R /Dest [{10 + count - 1} 0 R /Fit]>>");
        pdf.Obj(8, "<</Title (Linearizer test)>>");
        for (int i = 0; i < count; i++)
        {
            string own = i % 2 == 1 ? $" /Resources <</Font <</F1 3 0 R /F2 {10 + 2 * count + i} 0 R>> /XObject <</Fm 6 0 R>>>>" : "";
            string link = $" /Annots [<</Type /Annot /Subtype /Link /Rect [0 0 20 20] /Dest [{10 + (i + 1) % count} 0 R /Fit]>>]";
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Contents {10 + count + i} 0 R{own}{link}>>");
        }
        for (int i = 0; i < count; i++)
        {
            pdf.Stream(10 + count + i, "", $"BT /F1 12 Tf 20 100 Td (Page number {i + 1}) Tj ET q /Fm Do Q");
            if (i % 2 == 1) pdf.Obj(10 + 2 * count + i, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>");
        }
        string id = Convert.ToHexString(FileId);
        return pdf.Finish($"/Root 1 0 R /Info 8 0 R /ID [<{id}> <{id}>]");
    }

    public static PdfSecurity Secure(PdfCryptStrength strength, string user = "") =>
        PdfSecurity.Create(user, "owner", PdfPermissions.All, strength, FileId, new Random(3));

    public static string PigText(byte[] file)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(file);
        return string.Join("|", pig.GetPages().Select(p => p.Text));
    }

    public static string PigText(PdfDocument document)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.Source.ToArray());
        return string.Join("|", pig.GetPages().Select(p => p.Text));
    }

    /// <summary>With LAZYPDF_LINEARIZE_OUT naming a folder, the file is left there for other readers.</summary>
    public static byte[] Keep(string name, byte[] file)
    {
        string? folder = Environment.GetEnvironmentVariable("LAZYPDF_LINEARIZE_OUT");
        if (!string.IsNullOrEmpty(folder))
        {
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, name + ".pdf"), file);
        }
        return file;
    }

    /// <summary>
    /// Checks everything a reader relies on in a linearized file (Annex F): the parameters, both
    /// cross-reference sections against the real object positions, and the hint tables against
    /// the pages. Returns the parameters.
    /// </summary>
    public static Dictionary<string, long> Verify(byte[] file, string? password = null)
    {
        if (password is null) Keep($"verified-{Interlocked.Increment(ref _kept):D3}", file);
        string text = Encoding.Latin1.GetString(file);
        var starts = new SortedDictionary<long, int>();
        foreach (Match m in Regex.Matches(text, @"(?<=\n)(\d+) 0 obj\n")) starts[m.Index] = int.Parse(m.Groups[1].Value);
        var offsetOf = starts.ToDictionary(s => s.Value, s => s.Key);

        var lin = Regex.Match(text, @"/Linearized 1 /L (\d+) /H \[ (\d+) (\d+) \] /O (\d+) /E (\d+) /N (\d+) /T (\d+)\s*>>");
        Assert.True(lin.Success, "linearization dictionary");
        long Param(int i) => long.Parse(lin.Groups[i].Value);
        var parameters = new Dictionary<string, long> { ["L"] = Param(1), ["H0"] = Param(2), ["H1"] = Param(3), ["O"] = Param(4), ["E"] = Param(5), ["N"] = Param(6), ["T"] = Param(7) };
        Assert.Equal(file.Length, parameters["L"]);
        Assert.True(lin.Index < starts.Skip(1).First().Key);

        var sections = Regex.Matches(text, @"(?<=\n)xref\n(\d+) (\d+)\n").Cast<Match>().ToList();
        Assert.Equal(2, sections.Count);
        var (first, main) = (sections[0], sections[1]);
        Assert.Matches(@"startxref\n" + first.Index + @"\n%%EOF\n$", text[^40..]);
        Assert.Equal(parameters["T"], main.Index + "xref\n".Length + $"0 {main.Groups[2].Value}".Length);
        Assert.Equal('\n', text[(int)parameters["T"]]);
        Assert.Equal(0, int.Parse(main.Groups[1].Value));
        int mainCount = int.Parse(main.Groups[2].Value);
        Assert.Equal(mainCount, int.Parse(first.Groups[1].Value));
        int firstCount = int.Parse(first.Groups[2].Value);

        var firstTrailer = Regex.Match(text[first.Index..], @"trailer\n<<(?<d>.*?)>>\nstartxref\n0\n%%EOF\n");
        Assert.True(firstTrailer.Success);
        Assert.Contains($"/Size {mainCount + firstCount}", firstTrailer.Groups["d"].Value);
        Assert.Equal(main.Index, long.Parse(Regex.Match(firstTrailer.Groups["d"].Value, @"/Prev (\d+)").Groups[1].Value));
        Assert.Contains($"/Size {mainCount}", text[main.Index..]);

        void CheckEntries(Match section, int number, int count, bool freeFirst)
        {
            int at = section.Index + section.Length;
            for (int i = 0; i < count; i++, at += 20, number++)
            {
                string entry = text.Substring(at, 20);
                if (freeFirst && i == 0)
                {
                    Assert.Equal("0000000000 65535 f \n", entry);
                    continue;
                }
                Assert.Matches(@"^\d{10} 00000 n \n$", entry);
                Assert.Equal(offsetOf[number], long.Parse(entry[..10]));
            }
        }
        Assert.Equal(starts.First().Value, int.Parse(first.Groups[1].Value));
        CheckEntries(first, int.Parse(first.Groups[1].Value), firstCount, false);
        CheckEntries(main, 0, mainCount, true);

        long firstPageNumber = parameters["O"];
        long hintAt = parameters["H0"];
        Assert.True(starts.ContainsKey(hintAt));
        Assert.True(starts.ContainsKey(hintAt + parameters["H1"]));
        Assert.Matches(@"^\d+ 0 obj\n<</S \d+", text.Substring((int)hintAt, 30));

        using var document = PdfDocument.Open(file, password);
        Assert.True(document.IsLinearized);
        Assert.Equal(parameters["N"], document.Pages.Count);
        Assert.Equal(firstPageNumber, document.Pages[0].Reference.Number);
        VerifyHints(document, file, starts, offsetOf, parameters, main.Index);
        return parameters;
    }

    private static void VerifyHints(PdfDocument document, byte[] file, SortedDictionary<long, int> starts, Dictionary<int, long> offsetOf, Dictionary<string, long> lin, long mainAt)
    {
        long Next(long start) => starts.Keys.Where(k => k > start).DefaultIfEmpty(mainAt).Min();
        long LengthOf(int number) => Next(offsetOf[number]) - offsetOf[number];
        var hintObject = document.Get(starts[lin["H0"]]) as PdfStream ?? throw new Xunit.Sdk.XunitException("hint stream");
        byte[] data = document.RawData(hintObject);
        long sharedAt = document.Integer(hintObject.Dictionary, "S")!.Value;
        long hintLength = lin["H1"];

        var r = new BitReader(data);
        long minObjects = r.Read(32), firstAt = r.Read(32);
        int bitsObjects = (int)r.Read(16);
        long minLength = r.Read(32);
        int bitsLength = (int)r.Read(16);
        long minOffset = r.Read(32);
        int bitsOffset = (int)r.Read(16);
        long minContent = r.Read(32);
        int bitsContent = (int)r.Read(16);
        int bitsCount = (int)r.Read(16), bitsId = (int)r.Read(16), bitsNumerator = (int)r.Read(16);
        Assert.Equal(0, bitsNumerator);
        r.Read(16);

        int pages = (int)lin["N"];
        long[] Column(int bits, long least)
        {
            var values = Enumerable.Range(0, pages).Select(_ => least + r.Read(bits)).ToArray();
            r.Align();
            return values;
        }
        long[] objects = Column(bitsObjects, minObjects), lengths = Column(bitsLength, minLength);
        long[] counts = Column(bitsCount, 0);
        var ids = counts.Select(c => Enumerable.Range(0, (int)c).Select(_ => (int)r.Read(bitsId)).ToArray()).ToArray();
        r.Align();
        long[] offsets = Column(bitsOffset, minOffset), spans = Column(bitsContent, minContent);
        Assert.Equal(sharedAt, r.Position);

        long sharedFirst = r.Read(32), sharedFirstAt = r.Read(32), sharedFirstPage = r.Read(32), sharedTotal = r.Read(32);
        Assert.Equal(0, r.Read(16));
        long minGroup = r.Read(32);
        int bitsGroup = (int)r.Read(16);
        var groups = Enumerable.Range(0, (int)sharedTotal).Select(_ => minGroup + r.Read(bitsGroup)).ToArray();
        r.Align();
        Assert.All(Enumerable.Range(0, (int)sharedTotal), _ => Assert.Equal(0, r.Read(1)));
        r.Align();
        if (document.Integer(hintObject.Dictionary, "O") is { } outlineAt)
        {
            Assert.Equal(outlineAt, r.Position);
            long outlineFirst = r.Read(32), outlineStart = r.Read(32) + hintLength, outlineCount = r.Read(32), outlineLength = r.Read(32);
            Assert.Equal(((PdfReference)document.Catalog["Outlines"]!).Number, outlineFirst);
            Assert.Equal(offsetOf[(int)outlineFirst], outlineStart);
            Assert.Equal(outlineCount, starts.Count(s => s.Key >= outlineStart && s.Key < outlineStart + outlineLength));
        }
        Assert.Equal(data.Length, r.Position);

        // Page ranges follow each other from the first page's object (offsets in the tables leave out the hint stream).
        var pageStart = new long[pages];
        pageStart[0] = firstAt + hintLength;
        Assert.Equal(offsetOf[(int)lin["O"]], pageStart[0]);
        for (int p = 1; p < pages; p++) pageStart[p] = pageStart[p - 1] + lengths[p - 1];
        Assert.Equal(lin["E"], pageStart[0] + lengths[0]);
        if (pages > 1) Assert.Equal(offsetOf[document.Pages[1].Reference.Number], lin["E"]);

        // The groups: the first page's objects one by one, then the shared section's.
        var groupObjects = new int[groups.Length][];
        long cursor = pageStart[0];
        for (int g = 0; g < groups.Length; g++)
        {
            if (g == sharedFirstPage) cursor = sharedFirstAt + hintLength;
            Assert.True(starts.TryGetValue(cursor, out int number), $"group {g} starts at an object");
            Assert.Equal(groups[g], LengthOf(number));
            groupObjects[g] = [number];
            cursor += groups[g];
        }
        if (sharedTotal > sharedFirstPage) Assert.Equal(sharedFirst, groupObjects[sharedFirstPage][0]);

        for (int p = 0; p < pages; p++)
        {
            long end = pageStart[p] + lengths[p];
            var inside = starts.Where(s => s.Key >= pageStart[p] && s.Key < end).Select(s => s.Value).ToList();
            Assert.Equal(objects[p], inside.Count);
            Assert.Equal(document.Pages[p].Reference.Number, inside[0]);

            var reached = Reach(document, document.Pages[p].Reference.Number).Where(n => !inside.Contains(n)).Order().ToList();
            var listed = ids[p].Select(id => groupObjects[id][0]).Order().ToList();
            // What the page uses is in its range, in a group, in the document-level section before the hint
            // stream, or among the objects that follow the shared section.
            Assert.Subset(reached.ToHashSet(), listed.ToHashSet());
            foreach (int n in reached.Except(listed))
            {
                Assert.True(offsetOf[n] < lin["H0"] || offsetOf[n] >= cursor, $"page {p}: object {n} is unlisted but in the page sections");
            }
            if (p == 0) Assert.Empty(ids[p]);

            var contents = ContentNumbers(document, document.Pages[p]).Where(inside.Contains).ToList();
            if (contents.Count > 0)
            {
                Assert.Equal(offsetOf[contents[0]] - pageStart[p], offsets[p]);
                Assert.Equal(offsetOf[contents[^1]] + LengthOf(contents[^1]) - offsetOf[contents[0]], spans[p]);
            }
            else
            {
                Assert.Equal(0, offsets[p]);
                Assert.Equal(0, spans[p]);
            }
        }
    }

    private static IEnumerable<int> ContentNumbers(PdfDocument document, PdfPage page)
    {
        var contents = page.Dictionary["Contents"];
        if (contents is PdfReference reference)
        {
            yield return reference.Number;
            contents = document.Get(reference.Number);
        }
        if (contents is PdfArray array)
        {
            foreach (var item in array.Items.OfType<PdfReference>()) yield return item.Number;
        }
    }

    /// <summary>The objects a page uses: all it reaches except the other pages and its own /Parent.</summary>
    public static HashSet<int> Reach(PdfDocument document, int pageNumber)
    {
        var pages = document.Pages.Select(p => p.Reference.Number).ToHashSet();
        var seen = new HashSet<int> { pageNumber };
        var todo = new Stack<PdfObject>();
        void Push(PdfObject? value, bool top)
        {
            switch (value)
            {
                case PdfReference r when !pages.Contains(r.Number) && seen.Add(r.Number):
                    if (document.Get(r.Number) is { } target) todo.Push(target);
                    break;
                case PdfArray a:
                    foreach (var i in a.Items) Push(i, false);
                    break;
                case PdfStream s:
                    Push(s.Dictionary, false);
                    break;
                case PdfDictionary d:
                    foreach (var (key, v) in d.Entries)
                    {
                        if (!(top && key == "Parent")) Push(v, false);
                    }
                    break;
            }
        }
        Push(document.Get(pageNumber), true);
        while (todo.Count > 0) Push(todo.Pop(), false);
        seen.Remove(pageNumber);
        return seen;
    }

    private sealed class BitReader(byte[] data)
    {
        private int _bit;

        public int Position => (_bit + 7) / 8;

        public long Read(int bits)
        {
            long value = 0;
            for (int i = 0; i < bits; i++, _bit++) value = value << 1 | (long)(data[_bit >> 3] >> (7 - (_bit & 7)) & 1);
            return value;
        }

        public void Align() => _bit = (_bit + 7) & ~7;
    }
}
