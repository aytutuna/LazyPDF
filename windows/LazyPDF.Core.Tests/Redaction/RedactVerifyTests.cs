using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactVerifyTests
{
    [Fact]
    public void TextStillInsideAMarkIsFound()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (alphabet here) Tj ET");
        var marks = RedactionKit.MarksOf(document, 0, "alphabet");
        var check = PdfRedactor.Verify(document.SaveRewrite(), marks, []);
        Assert.False(check.IsClean);
        Assert.Contains("page 1", Assert.Single(check.Problems));
        Assert.DoesNotContain("alphabet", check.Problems[0]);
    }

    [Fact]
    public void OverlayTextInsideTheMarkIsNotAProblem()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (hidden) Tj ET");
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "hidden").Select(m => m with { OverlayText = "REDACTED" }).ToList());
        Assert.True(result.Verification.IsClean);
        Assert.False(PdfRedactor.Verify(result.Bytes, RedactionKit.MarksOf(PdfDocument.Open(result.Bytes), 0, "REDACTED"), [], []).IsClean);
    }

    [Fact]
    public void PacketIsSearchedByItsTextAndByItsBytes()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (plain) Tj ET");
        var packet = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") },
            Encoding.UTF8.GetBytes("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF><rdf:Description><xmpG:mode>RGB</xmpG:mode><dc:title>a &#103;izli b</dc:title></rdf:Description></rdf:RDF></x:xmpmeta>")));
        document.Catalog["Metadata"] = packet;
        byte[] bytes = document.SaveRewrite();
        // A name holds a word as much as a text does, and the bytes are searched besides the text.
        Assert.False(PdfRedactor.Verify(bytes, [], ["mode"]).IsClean);
        Assert.True(PdfRedactor.Verify(bytes, [], ["absent"]).IsClean);
        Assert.False(PdfRedactor.Verify(bytes, [], ["gizli"]).IsClean);
    }

    [Fact]
    public void RemovedStringsAreLookedForInEveryObjectAndStream()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (plain) Tj ET");
        document.Trailer["Info"] = document.Add(new PdfDictionary { ["Subject"] = PdfText.ToObject("about Gizli Belge") });
        document.Catalog["Names"] = document.Add(new PdfDictionary());
        var embedded = document.Add(new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") }, PdfFilterEncoders.Flate(Encoding.BigEndianUnicode.GetBytes("xx Dosya Adı Gizli Belge yy"))));
        document.Catalog["Extra"] = embedded;
        var check = PdfRedactor.Verify(document.SaveRewrite(), [], ["Gizli Belge", "absent text"]);
        Assert.Equal(2, check.Problems.Count);
        Assert.All(check.Problems, p => Assert.DoesNotContain("Gizli", p));
    }

    [Fact]
    public void FontProgramsAndCodeMapsAreNotSearched()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (plain) Tj ET");
        var program = document.Add(new PdfStream(new PdfDictionary(), Encoding.Latin1.GetBytes("glyf table with leaked words in a name record")));
        var map = document.Add(new PdfStream(new PdfDictionary(), Encoding.Latin1.GetBytes("%%BeginResource: CMap (leaked words)")));
        document.Catalog["Extra"] = document.Add(new PdfDictionary { ["Type"] = new PdfName("FontDescriptor"), ["FontFile2"] = program, ["ToUnicode"] = map });
        Assert.True(PdfRedactor.Verify(document.SaveRewrite(), [], ["leaked words"]).IsClean);
    }

    [Fact]
    public void ContentOperandsOtherThanTheShownTextAreSearchedToo()
    {
        using var document = RedactionKit.Page("/Span <</ActualText (leaked words)>> BDC BT /F1 12 Tf 100 700 Td (leaked words) Tj ET EMC");
        var check = PdfRedactor.Verify(document.SaveRewrite(), [], ["leaked words"]);
        Assert.Single(check.Problems);
    }

    [Fact]
    public void ABrokenOutputIsReported()
    {
        var check = PdfRedactor.Verify([1, 2, 3], [], []);
        Assert.Equal(RedactionText.DoesNotOpen, Assert.Single(check.Problems));
    }
}
