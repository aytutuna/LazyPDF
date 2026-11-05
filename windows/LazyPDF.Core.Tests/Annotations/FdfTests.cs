using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FdfTests
{
    private static readonly DateTimeOffset Day = new(2026, 3, 1, 9, 0, 0, TimeSpan.Zero);

    private static PdfDocument Commented()
    {
        var document = Blank(2);
        var writer = new PdfAnnotationWriter(document);
        var note = writer.AddNote(document.Pages[0], new PdfRect(50, 100, 70, 120), new AnnotationInfo("Ayşe", "başlık: şiir", "Review", Day));
        PdfComments.Reply(document, note, "yanıt", "Can", Day.AddHours(1));
        PdfComments.SetStatus(document, note, ReviewStatus.Accepted, "Can", Day.AddHours(2));
        writer.AddTextMarkup(document.Pages[1], AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(50, 700, 150, 714))], new AnnotationInfo("Ali", "marked", null, Day));
        writer.AddStamp(document.Pages[1], new PdfRect(300, 600, 500, 660), "Approved");
        return document;
    }

    [Fact]
    public void ExportWriteReadKeepsEveryAnnotationAndItsLinks()
    {
        var source = Commented();
        var fdf = PdfFdf.Export(source, "book.pdf");
        var read = PdfFdf.Read(PdfFdf.Write(fdf));

        Assert.Equal("book.pdf", read.FileName);
        Assert.Equal(5, read.Annotations.Count);
        Assert.Equal([0, 0, 0, 1, 1], read.Annotations.Select(a => a.PageIndex).Order());
        var note = read.Annotations.Single(a => a.Dictionary["Contents"] is PdfString s && PdfText.Decode(s.Bytes) == "başlık: şiir");
        Assert.Equal("Ayşe", PdfText.Decode(((PdfString)note.Dictionary["T"]!).Bytes));
        var replies = read.Annotations.Where(a => a.Dictionary["IRT"] is PdfReference).ToList();
        Assert.Equal(2, replies.Count);
        Assert.All(replies, r => Assert.Same(note.Dictionary, read.Resolve(r.Dictionary["IRT"])));
        var stamp = read.Annotations.Single(a => (a.Dictionary["Subtype"] as PdfName)?.Value == "Stamp");
        Assert.IsType<PdfStream>(read.Resolve(((PdfDictionary)stamp.Dictionary["AP"]!)["N"]));
    }

    [Fact]
    public void ImportRebuildsThemInAnotherDocument()
    {
        var target = Blank(2);
        var result = PdfFdf.Import(target, PdfFdf.Read(PdfFdf.Write(PdfFdf.Export(Commented()))));
        Assert.Equal(new FdfImportResult(5, 0, 0), result);

        var reopened = Reopen(target);
        Assert.Equal(3, PdfAnnotations.Read(reopened, reopened.Pages[0]).Count);
        Assert.Equal(2, PdfAnnotations.Read(reopened, reopened.Pages[1]).Count);
        var comments = PdfComments.List(reopened);
        var thread = comments.Single(c => c.Text == "başlık: şiir");
        Assert.Equal(2, thread.Replies.Count);
        Assert.Equal(ReviewStatus.Accepted, thread.Status);
        Assert.All(PdfAnnotations.ReadAll(reopened), a => Assert.True(a.HasAppearance));
        Assert.All(PdfAnnotations.ReadAll(reopened), a => Assert.False(a.Dictionary.ContainsKey("Page")));
        Assert.All(PdfAnnotations.ReadAll(reopened), a => Assert.NotNull(a.Dictionary["P"]));
    }

    [Fact]
    public void ImportingTwiceSkipsWhatIsAlreadyThere()
    {
        var target = Blank(2);
        var fdf = PdfFdf.Read(PdfFdf.Write(PdfFdf.Export(Commented())));
        PdfFdf.Import(target, fdf);
        var again = PdfFdf.Import(target, fdf);
        Assert.Equal(0, again.Imported);
        Assert.Equal(5, again.Skipped);
        Assert.Equal(5, PdfAnnotations.ReadAll(target).Count);
    }

    [Fact]
    public void PagesOutsideTheDocumentAreSkippedAndTheirLinksCut()
    {
        var fdf = PdfFdf.Export(Commented());
        var target = Blank(1);
        var result = PdfFdf.Import(target, fdf);
        Assert.Equal(3, result.Imported);
        Assert.Equal(2, result.Skipped);
        Assert.Equal(3, PdfAnnotations.ReadAll(target).Count);
        Assert.Equal(3, target.ObjectNumbers.Count(n => target.Get(n) is PdfDictionary d && d.ContainsKey("Subtype") && d.ContainsKey("Rect")));
    }

    [Fact]
    public void ExportCanBeNarrowedByType()
    {
        var fdf = PdfFdf.Export(Commented(), types: new HashSet<AnnotationType> { AnnotationType.Highlight });
        Assert.Equal("Highlight", ((PdfName)Assert.Single(fdf.Annotations).Dictionary["Subtype"]!).Value);
    }

    [Fact]
    public void AnnotationWithoutAppearanceGetsOneOnImport()
    {
        string text = "%FDF-1.2\n1 0 obj\n<</FDF<</F (a.pdf) /Annots [2 0 R]>>>>\nendobj\n" +
                      "2 0 obj\n<</Subtype /Square /Page 0 /Rect [10 10 90 60] /C [1 0 0] /NM (sq)>>\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF";
        var target = Blank(1);
        var result = PdfFdf.Import(target, PdfFdf.Read(Encoding.Latin1.GetBytes(text)));
        Assert.Equal(1, result.Imported);
        Assert.True(PdfAnnotations.Read(target, target.Pages[0]).Single().HasAppearance);
    }

    [Fact]
    public void ReadsFieldsWithKidsAndDottedNames()
    {
        string text = "%FDF-1.2\n1 0 obj\n<</FDF<</Fields[<</T (person) /Kids[<</T (name) /V (Ayşe)>> <</T (tick) /V /Yes>> <</T (many) /V [(a) (b)]>>]>> <</T (lone) /V <FEFF015F>>>]>>>>\nendobj\ntrailer\n<</Root 1 0 R>>\n";
        var fdf = PdfFdf.Read(Encoding.Latin1.GetBytes(text.Replace("Ayşe", "Ayse")));
        var flat = fdf.FlatFields();
        Assert.Equal(["person.name", "person.tick", "person.many", "lone"], flat.Select(f => f.Key));
        Assert.Equal("Ayse", PdfText.Decode(((PdfString)flat[0].Value!).Bytes));
        Assert.Equal("Yes", ((PdfName)flat[1].Value!).Value);
        Assert.Equal(2, ((PdfArray)flat[2].Value!).Items.Count);
        Assert.Equal("ş", PdfText.Decode(((PdfString)flat[3].Value!).Bytes));
        Assert.Empty(fdf.Annotations);
    }

    [Fact]
    public void FieldsRoundTripThroughWrite()
    {
        var fdf = new FdfFile { FileName = "form.pdf" };
        fdf.Fields.Add(new FdfField("a", PdfText.ToObject("one"), []));
        fdf.Fields.Add(new FdfField("group", null, [new FdfField("b", new PdfName("Off"), [])]));
        var read = PdfFdf.Read(PdfFdf.Write(fdf));
        Assert.Equal(["a", "group.b"], read.FlatFields().Select(f => f.Key));
        Assert.StartsWith("%FDF-1.2", Encoding.Latin1.GetString(PdfFdf.Write(fdf)));
    }

    [Fact]
    public void StreamsKeepTheirBytesWhateverTheLengthSays()
    {
        byte[] payload = [.. Enumerable.Range(0, 300).Select(i => (byte)i)];
        foreach (string length in new[] { "300", "5", "999999", "" })
        {
            var head = Encoding.Latin1.GetBytes($"%FDF-1.2\n1 0 obj\n<</FDF<</Annots[2 0 R]>>>>\nendobj\n2 0 obj\n<</Subtype /Stamp /Page 0 /Rect [0 0 9 9] /AP <</N 3 0 R>>>>\nendobj\n3 0 obj\n<</Type /XObject /Subtype /Form /BBox [0 0 9 9] {(length.Length > 0 ? "/Length " + length : "")}>>\nstream\n");
            byte[] file = [.. head, .. payload, .. "\nendstream\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF"u8];
            var fdf = PdfFdf.Read(file);
            var stream = (PdfStream)fdf.Resolve(((PdfDictionary)fdf.Annotations[0].Dictionary["AP"]!)["N"])!;
            Assert.Equal(payload, stream.Data);
        }
    }

    [Fact]
    public void GarbageIsRefusedOrSurvived()
    {
        Assert.Throws<PdfReadException>(() => PdfFdf.Read("hello"u8.ToArray()));
        Assert.Throws<PdfReadException>(() => PdfFdf.Read([]));
        Assert.Throws<PdfReadException>(() => PdfFdf.Read(TestPdf.Simple(1)));
        var random = new Random(7);
        var valid = PdfFdf.Write(PdfFdf.Export(Commented()));
        for (int round = 0; round < 40; round++)
        {
            byte[] broken = (byte[])valid.Clone();
            for (int i = 0; i < 20; i++) broken[random.Next(broken.Length)] = (byte)random.Next(256);
            try
            {
                var fdf = PdfFdf.Read(broken);
                PdfFdf.Import(Blank(2), fdf);
            }
            catch (PdfReadException)
            {
            }
        }
    }

    [Fact]
    public void AnObjectNumberAtTheLimitDoesNotWrap()
    {
        var fdf = new FdfFile();
        fdf.Add(int.MaxValue, new PdfDictionary());
        Assert.Throws<PdfReadException>(() => fdf.Reserve());
        Assert.Throws<PdfReadException>(() => PdfFdf.Write(fdf));
    }

    [Fact]
    public void TheFileOnlyHoldsWhatTheAnnotationsReach()
    {
        var fdf = PdfFdf.Export(Commented());
        string text = Encoding.Latin1.GetString(PdfFdf.Write(fdf));
        Assert.DoesNotContain("/Pages", text);
        Assert.DoesNotContain("/Kids", text);
        Assert.DoesNotContain("/Parent 2 0 R", text);
    }

    [Fact]
    public void WritingAFileThatWasReadKeepsOneCatalog()
    {
        byte[] first = PdfFdf.Write(PdfFdf.Export(Commented()));
        byte[] second = PdfFdf.Write(PdfFdf.Read(first));
        Assert.Single(Regex.Matches(Encoding.Latin1.GetString(second), "/FDF"));
        Assert.Equal(PdfFdf.Read(first).Annotations.Count, PdfFdf.Read(second).Annotations.Count);
    }
}
