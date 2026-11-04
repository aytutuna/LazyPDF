using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class CompareReviewTests
{
    private static string Shape(ComparisonResult r) =>
        string.Join(' ', r.Pages.Select(p => p.IsAdded ? $"+{p.NewIndex}" : p.IsRemoved ? $"-{p.OldIndex}" : p.Moved ? $"{p.OldIndex}>{p.NewIndex}" : $"{p.OldIndex}={p.NewIndex}"));

    [Fact]
    public void EditedPageIsPairedWhenAnotherPageWasInsertedBesideIt()
    {
        string[] edited = [.. Page("a").Select(line => string.Join(' ', line.Split(' ').Select((w, i) => i % 3 == 2 ? $"zz{i}" : w)))];
        var result = Compare([Page("a"), Page("b")], [Page("x"), edited, Page("b")]);
        Assert.Equal("+0 0=1 1=2", Shape(result));
        Assert.Contains(result.Changes, c => c.Area == ChangeArea.Text && c.OldPage == 0 && c.NewPage == 1);
    }

    [Fact]
    public void SlidBlockStaysClearOfTheHunkBeforeIt()
    {
        var result = Compare([["alpha beta", "alpha beta gamma delta"]], [["omega beta gamma zeta"]]);
        var removed = Assert.Single(result.Changes, c => c.Kind == ChangeKind.Removed);
        Assert.Equal("alpha beta", removed.OldText);
        Assert.InRange(Assert.Single(removed.OldQuads).Bounds.Bottom, 700, 725);
        Assert.DoesNotContain(result.Changes, c => c.Area == ChangeArea.Format);
    }

    [Fact]
    public void ListBoxSelectionBeyondTheFirstChoiceIsACompare()
    {
        static PdfDocument Pick(params string[] choices)
        {
            using var document = Doc(Page("form"));
            var form = PdfForm.Read(document);
            form.AddField(new FieldSpec(FieldKind.ListBox, "colors", 0, new PdfRect(100, 400, 200, 460))
            {
                Options = [new("A", "A"), new("B", "B"), new("C", "C")],
                Flags = FieldFlags.MultiSelect,
            });
            form.SetChoices("colors", choices);
            return Open(document.SaveRewrite());
        }
        using var before = Pick("A", "B");
        using var after = Pick("A", "C");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal((ChangeArea.Document, ChangeKind.Changed, "A; B", "A; C"), (change.Area, change.Kind, change.OldText, change.NewText));
    }

    [Fact]
    public void AddedPictureAndNoteHaveNoQuadOnTheOldSide()
    {
        using var plain = Open(Bytes([[new("Some text")]]));
        using var withPicture = Picture("");
        var added = Assert.Single(PdfComparer.Compare(plain, withPicture).Changes);
        Assert.Empty(added.OldQuads);
        Assert.Single(added.NewQuads);
        var removed = Assert.Single(PdfComparer.Compare(withPicture, plain).Changes);
        Assert.Empty(removed.NewQuads);
        Assert.Single(removed.OldQuads);
    }

    [Fact]
    public void InsertionAfterAHebrewWordIsAnchoredAtItsLeftEdge()
    {
        // Codes 1 to 5 are Hebrew letters; the text is set in visual order, so the first letter of a word is its rightmost glyph.
        PdfDocument Make(string line) => TextTestPdf.Page(TextTestPdf.Line(100, 700, line), "", (1, "א"), (2, "ב"), (3, "ג"), (4, "ד"), (5, "ה"));
        using var before = Make(@"\004\003 \002\001");
        using var after = Make(@"\005 \004\003 \002\001");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Added, change.Kind);
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Left, 99, 101);
    }

    internal static PdfDocument Picture(string imageKeys, Action<TestPdf, int>? extra = null)
    {
        var bytes = Bytes([[new("Some text")]], more: (pdf, first) =>
        {
            pdf.Stream(first, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode " + imageKeys, "00FF00FF>");
            pdf.Stream(first + 1, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", "FF80FF80>");
            extra?.Invoke(pdf, first + 2);
        });
        string file = TestPdf.Text(bytes)
            .Replace("/Resources <</Font", "/Resources <</XObject <</Im0 8 0 R>> /Font")
            .Replace("Tj ET\n", "Tj ET\nq 80 0 0 60 100 300 cm /Im0 Do Q ");
        return Open(TestPdf.Latin(file));
    }

    /// <summary>A picture whose tint transform is a stitching function (object <paramref name="top"/>) of two others.</summary>
    private static PdfDocument Tinted(int top, int low, int high, string c1) => Picture($"/ColorSpace [/Separation /Spot /DeviceGray {top} 0 R]", (pdf, _) =>
    {
        pdf.Obj(top, $"<</FunctionType 3 /Domain [0 1] /Functions [{low} 0 R {high} 0 R] /Bounds [0.5] /Encode [0 1 0 1]>>");
        pdf.Obj(low, "<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>");
        pdf.Obj(high, $"<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [{c1}] /N 1>>");
    });

    [Fact]
    public void ColourSpaceIsJudgedByWhatItReferencesNotByObjectNumbers()
    {
        using var file = Tinted(10, 11, 12, "1");
        using var renumbered = Tinted(12, 10, 11, "1");
        using var changed = Tinted(10, 11, 12, "0.5");
        Assert.True(PdfComparer.Compare(file, renumbered).IsIdentical);
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(file, changed).Changes).Detail);
    }

    [Fact]
    public void DecodeParametersOnTheSameBytesAreSeen()
    {
        using var black = Picture("/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 2 /BlackIs1 true>>");
        using var white = Picture("/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 2 /BlackIs1 false>>");
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(black, white).Changes).Detail);
    }

    [Fact]
    public void StreamReachedThroughManyReferencesIsReadOnce()
    {
        var zeros = new MemoryStream();
        using (var z = new System.IO.Compression.ZLibStream(zeros, System.IO.Compression.CompressionLevel.Optimal, true)) z.Write(new byte[8 << 20]);
        string row = "[" + string.Concat(Enumerable.Repeat("11 0 R ", 64)) + "]";
        string rows = "[" + string.Concat(Enumerable.Repeat(row + " ", 64)) + "]";
        using var file = Picture($"/ColorSpace {rows}", (pdf, _) => pdf.Stream(11, "/Filter /FlateDecode", zeros.ToArray()));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        PdfComparer.Compare(file, file);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5), watch.Elapsed.ToString());
    }

    [Fact]
    public void InsertionAfterANumberInARightToLeftLineIsAnchoredAtTheNumbersLeftEdge()
    {
        PdfDocument Make(string line) => TextTestPdf.Page(TextTestPdf.Line(100, 700, line), "", (1, "א"), (2, "ב"), (5, "ה"));
        using var before = Make(@"12 \002\001");
        using var after = Make(@"\005 12 \002\001");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Added, change.Kind);
        Assert.InRange(Assert.Single(change.OldQuads).Bounds.Left, 99, 101);
    }

    [Fact]
    public void EditedPageIsPairedWhenOneIsInsertedAndOneRemovedBesideIt()
    {
        string[] Edit(string[] page) => [.. page.Select(line => string.Join(' ', line.Split(' ').Select((w, i) => i % 3 == 2 ? $"zz{i}" : w)))];
        var result = Compare([Page("a"), Page("b"), Page("c")], [Page("x"), Edit(Page("a")), Edit(Page("b"))]);
        Assert.Equal("-2 +0 0=1 1=2", Shape(result));
    }

    [Fact]
    public void PagesAppendedAtTheEndDoNotTakeThePartnerOfAnEditedPoorPage()
    {
        var result = Compare([["Title page"]], [["Title pages"], []]);
        Assert.Equal("0=0 +1", Shape(result));
    }

    [Fact]
    public void SoftMaskAndDecodeChangesOnTheSameSamplesAreSeen()
    {
        using var plain = Picture("");
        using var masked = Picture("/SMask 9 0 R");
        using var inverted = Picture("/Decode [1 0]");
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(plain, masked).Changes).Detail);
        Assert.Equal(CompareText.ImageReplaced, Assert.Single(PdfComparer.Compare(plain, inverted).Changes).Detail);
        using var again = Picture("/Decode [1 0]");
        Assert.True(PdfComparer.Compare(inverted, again).IsIdentical);
    }

    [Fact]
    public void RespelledValuesDoNotMakeAPictureReplaced()
    {
        using var hex = Picture("/ColorSpace [/Indexed /DeviceGray 1 <00FF>]");
        using var literal = Picture(@"/ColorSpace [/Indexed /DeviceGray 1 (\000\377)]");
        Assert.True(PdfComparer.Compare(hex, literal).IsIdentical);
        using var whole = Picture("/Decode [1 0]");
        using var real = Picture("/Decode [1.0 0.0]");
        Assert.True(PdfComparer.Compare(whole, real).IsIdentical);
    }

    [Fact]
    public void RotationThatKeepsTheSizeIsAPageChange()
    {
        using var upright = Open(Bytes([[new("Some text")]]));
        using var turned = Open(Bytes([[new("Some text")]], pageKeys: "/Rotate 180"));
        var change = Assert.Single(PdfComparer.Compare(upright, turned).Changes);
        Assert.Equal((ChangeKind.Changed, ChangeArea.Page), (change.Kind, change.Area));
        Assert.Contains("180", change.Detail);

        using var square = Open(Bytes([[new("Some text")]], pageKeys: "/MediaBox [0 0 600 600]"));
        using var squareTurned = Open(Bytes([[new("Some text")]], pageKeys: "/MediaBox [0 0 600 600] /Rotate 90"));
        Assert.Contains(PdfComparer.Compare(square, squareTurned).Changes, c => c.Area == ChangeArea.Page);
    }

    /// <summary>A file with two attachments; the tree keys differ but both specifications name the file report.pdf.</summary>
    private static PdfDocument Reports(string first, string second, bool undecodable = false)
    {
        using var document = Doc(Page("files"));
        PdfAttachments.Add(document, "a.txt", System.Text.Encoding.ASCII.GetBytes(first));
        PdfAttachments.Add(document, "b.txt", System.Text.Encoding.ASCII.GetBytes(second));
        foreach (var attachment in PdfAttachments.List(document))
        {
            var spec = (PdfDictionary)document.Resolve(attachment.Spec)!;
            spec["UF"] = PdfText.ToObject("report.pdf");
            spec["F"] = PdfText.ToObject("report.pdf");
            if (undecodable) PdfAttachments.StreamOf(document, attachment)!.Dictionary["Filter"] = new PdfName("NoSuchDecode");
        }
        return Open(document.SaveRewrite());
    }

    [Fact]
    public void SecondFileWithTheSameNameIsCompared()
    {
        using var before = Reports("one", "two");
        using var after = Reports("one", "changed");
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeArea.Document, change.Area);
        Assert.Contains("report.pdf (2)", change.Detail);
    }

    [Fact]
    public void AttachmentThatDoesNotDecodeIsComparedByItsStoredBytes()
    {
        using var before = Reports("one", "two", undecodable: true);
        using var same = Reports("one", "two", undecodable: true);
        using var other = Reports("one", "three", undecodable: true);
        Assert.True(PdfComparer.Compare(before, same).IsIdentical);
        Assert.Single(PdfComparer.Compare(before, other).Changes);
    }

    [Fact]
    public void RemovalFromAPageWithNoWordsLeftIsMarkedWhereItWas()
    {
        using var a = Doc([["alpha beta gamma"]]);
        using var b = Doc([Array.Empty<string>()]);
        var result = PdfComparer.Compare(a, b);
        var change = Assert.Single(result.Changes);
        Assert.Equal(ChangeKind.Removed, change.Kind);
        Assert.Empty(change.NewQuads);
        var bytes = ComparisonReport.Write(b, result, "old.pdf", "new.pdf");
        using var report = PdfDocument.Open(bytes);
        var mark = Assert.Single(PdfAnnotations.Read(report, report.Pages[1]), m => m.Type == AnnotationType.Highlight);
        Assert.Equal("Was: alpha beta gamma", mark.Contents);
        using var pig = PigDocument.Open(bytes);
        Assert.Equal(2, pig.NumberOfPages);
    }
}
