using System.Text;
using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class MetadataTests
{
    private const string Packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" pdfaid:part="2" pdfaid:conformance="B" pdf:Producer="Old producer"
            xmp:CreatorTool="Old tool" xmp:CreateDate="2020-01-02T03:04:05+01:00">
           <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/"><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """;

    private static PdfDocument WithXmp(string xml, string streamEntries = "", string info = "") =>
        StructureFixtures.File("/Metadata 30 0 R", pdf =>
        {
            pdf.Stream(30, "/Type /Metadata /Subtype /XML " + streamEntries, xml);
            if (info.Length > 0) pdf.Obj(31, info);
        }, pageEntries: "");

    private static DocumentMetadata Sample() => new(
        "Annual report", "A. Writer", "Numbers", "money, year", "Word", "Lazy",
        new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.FromHours(3)), new DateTimeOffset(2026, 2, 3, 4, 5, 6, TimeSpan.FromHours(-5)),
        new Dictionary<string, string> { ["Department"] = "Finance", ["Code"] = "42" });

    [Fact]
    public void WritesAndReadsInfoOfAFileWithoutOne()
    {
        var document = StructureFixtures.Open();
        Assert.Null(document.Info);
        Sample().Write(document);
        var reopened = StructureFixtures.Reopen(document);
        var read = DocumentMetadata.Read(reopened);
        var expected = Sample();
        Assert.Equal((expected.Title, expected.Author, expected.Subject, expected.Keywords, expected.Creator, expected.Producer),
                     (read.Title, read.Author, read.Subject, read.Keywords, read.Creator, read.Producer));
        Assert.Equal(expected.Created, read.Created);
        Assert.Equal(expected.Modified, read.Modified);
        Assert.Equal(expected.Custom, read.Custom);
    }

    [Fact]
    public void PdfPigReadsTheInfo()
    {
        var document = StructureFixtures.Open();
        Sample().Write(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        Assert.Equal("Annual report", pig.Information.Title);
        Assert.Equal("A. Writer", pig.Information.Author);
        Assert.Equal("Lazy", pig.Information.Producer);
    }

    [Fact]
    public void NonLatinTextUsesUtf16()
    {
        var document = StructureFixtures.Open();
        (Sample() with { Title = "Доклад", Custom = new Dictionary<string, string> { ["Note"] = "Türkçe ğ" } }).Write(document);
        var read = DocumentMetadata.Read(StructureFixtures.Reopen(document));
        Assert.Equal("Доклад", read.Title);
        Assert.Equal("Türkçe ğ", read.Custom["Note"]);
    }

    [Fact]
    public void NullAndEmptyRemoveKeys()
    {
        var document = StructureFixtures.Open();
        Sample().Write(document);
        (Sample() with { Title = null, Author = "", Created = null, Custom = new Dictionary<string, string>() }).Write(document);
        var read = DocumentMetadata.Read(document);
        Assert.Null(read.Title);
        Assert.Null(read.Author);
        Assert.Null(read.Created);
        Assert.Empty(read.Custom);
        Assert.False(document.Info!.ContainsKey("Title"));
        Assert.Equal("Numbers", read.Subject);
    }

    [Fact]
    public void EntriesNotInTheRecordAreKept()
    {
        var document = WithXmp("<x/>", info: "<</Title (T) /Trapped /True /Number 5 /Custom (x) /Dated (D:20200101000000Z)>>");
        document.Trailer["Info"] = new PdfReference(31, 0);
        var read = DocumentMetadata.Read(document);
        Assert.Equal(["Custom", "Dated"], read.Custom.Keys);
        (read with { Custom = new Dictionary<string, string>() }).Write(document);
        var info = document.Info!;
        Assert.Equal("/True", info["Trapped"]!.ToString());
        Assert.Equal("5", info["Number"]!.ToString());
        Assert.Null(info["Custom"]);
    }

    [Fact]
    public void StandardNamesAreNotCustom()
    {
        var document = StructureFixtures.Open();
        (Sample() with { Custom = new Dictionary<string, string> { ["Title"] = "sneaky", ["Trapped"] = "True", [""] = "x", ["Fine"] = "y" } }).Write(document);
        var read = DocumentMetadata.Read(document);
        Assert.Equal("Annual report", read.Title);
        Assert.Equal(["Fine"], read.Custom.Keys);
        Assert.Null(document.Info!["Trapped"]);
    }

    [Fact]
    public void ReadsDirectInfoAndBrokenDates()
    {
        var document = StructureFixtures.Open();
        document.Trailer["Info"] = new PdfDictionary { ["Title"] = new PdfString("direct"u8.ToArray(), false), ["CreationDate"] = new PdfString("yesterday"u8.ToArray(), false) };
        var read = DocumentMetadata.Read(document);
        Assert.Equal("direct", read.Title);
        Assert.Null(read.Created);
        read.Write(document);
        Assert.Equal("direct", DocumentMetadata.Read(StructureFixtures.Reopen(document)).Title);
    }

    [Fact]
    public void XmpFillsWhatInfoLacks()
    {
        var document = WithXmp(Packet);
        var read = DocumentMetadata.Read(document);
        Assert.Equal(("Old title", "Old producer", "Old tool"), (read.Title, read.Producer, read.Creator));
        Assert.Equal(new DateTimeOffset(2020, 1, 2, 3, 4, 5, TimeSpan.FromHours(1)), read.Created);
        Assert.Null(read.Author);
    }

    [Fact]
    public void InfoWinsOverXmp()
    {
        var document = WithXmp(Packet, info: "<</Title (From info)>>");
        document.Trailer["Info"] = new PdfReference(31, 0);
        Assert.Equal("From info", DocumentMetadata.Read(document).Title);
    }

    [Fact]
    public void WriteKeepsXmpInStepAndKeepsOtherProperties()
    {
        var document = WithXmp(Packet);
        Sample().Write(document);
        var reopened = StructureFixtures.Reopen(document);

        byte[] bytes = reopened.Data(reopened.Stream(reopened.Catalog, "Metadata")!);
        var xml = XDocument.Parse(Encoding.UTF8.GetString(bytes));
        XNamespace rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#", dc = "http://purl.org/dc/elements/1.1/", pdf = "http://ns.adobe.com/pdf/1.3/",
                   xmp = "http://ns.adobe.com/xap/1.0/", pdfx = "http://ns.adobe.com/pdfx/1.3/", id = "http://www.aiim.org/pdfa/ns/id/";
        var description = xml.Descendants(rdf + "Description").Single();
        Assert.Equal("Annual report", description.Element(dc + "title")!.Descendants(rdf + "li").Single().Value);
        Assert.Equal("A. Writer", description.Element(dc + "creator")!.Descendants(rdf + "li").Single().Value);
        Assert.Equal("Numbers", description.Element(dc + "description")!.Descendants(rdf + "li").Single().Value);
        Assert.Equal("money, year", description.Element(pdf + "Keywords")!.Value);
        Assert.Equal("Lazy", description.Element(pdf + "Producer")!.Value);
        Assert.Null(description.Attribute(pdf + "Producer"));
        Assert.Equal("Word", description.Element(xmp + "CreatorTool")!.Value);
        Assert.Equal("2026-01-02T03:04:05+03:00", description.Element(xmp + "CreateDate")!.Value);
        Assert.Equal("2026-02-03T04:05:06-05:00", description.Element(xmp + "ModifyDate")!.Value);
        Assert.Equal("Finance", description.Element(pdfx + "Department")!.Value);
        Assert.Equal("2", description.Attribute(id + "part")!.Value);

        // The packet markers stay, so tools that look for them still find the metadata.
        string text = Encoding.UTF8.GetString(bytes);
        Assert.Contains("<?xpacket begin=", text);
        Assert.Contains("<?xpacket end=\"w\"?>", text);
        Assert.Equal(("Annual report", "Numbers"), (DocumentMetadata.Read(reopened).Title, DocumentMetadata.Read(reopened).Subject));
        Assert.Equal(2, reopened.PdfAPart);
    }

    [Fact]
    public void RemovingAValueRemovesItFromXmp()
    {
        var document = WithXmp(Packet);
        (DocumentMetadata.Read(document) with { Title = null, Creator = null }).Write(document);
        string text = Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!));
        Assert.DoesNotContain("Old title", text);
        Assert.DoesNotContain("Old tool", text);
        Assert.Contains("Old producer", text);
    }

    [Fact]
    public void RewritingCustomKeysUpdatesTheirXmpCounterparts()
    {
        var document = WithXmp(Packet);
        (Sample() with { Custom = new Dictionary<string, string> { ["A"] = "1", ["bad key"] = "2" } }).Write(document);
        (Sample() with { Custom = new Dictionary<string, string> { ["B"] = "3" } }).Write(document);
        string text = Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!));
        Assert.DoesNotContain("pdfx:A", text);
        Assert.Contains(">3</pdfx:B>", text);
        Assert.DoesNotContain("bad key", text);
    }

    [Fact]
    public void FlateXmpIsStoredPlainAfterAWrite()
    {
        var document = StructureFixtures.File("/Metadata 30 0 R", pdf =>
            pdf.Stream(30, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", PdfFilterEncoders.Flate(Encoding.UTF8.GetBytes(Packet))));
        Sample().Write(document);
        var stream = document.Stream(document.Catalog, "Metadata")!;
        Assert.Null(stream.Dictionary["Filter"]);
        Assert.Contains("Annual report", Encoding.UTF8.GetString(document.Data(stream)));
        Assert.Contains("Annual report", Encoding.UTF8.GetString(StructureFixtures.Reopen(document).Data(StructureFixtures.Reopen(document).Stream(document.Catalog, "Metadata")!)));
    }

    [Fact]
    public void NoXmpIsNotMade()
    {
        var document = StructureFixtures.Open();
        Sample().Write(document);
        Assert.Null(document.Catalog["Metadata"]);
    }

    [Theory]
    [InlineData("this is not xml <<<")]
    [InlineData("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><nothing/></x:xmpmeta>")]
    [InlineData("<!DOCTYPE r [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">&b;</rdf:RDF>")]
    public void XmpThatCannotBeUsedIsLeftAlone(string xml)
    {
        var document = WithXmp(xml);
        Sample().Write(document);
        Assert.Equal(xml, Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!)));
        Assert.Equal("Annual report", DocumentMetadata.Read(document).Title);
    }

    [Fact]
    public void XmpBehindACryptFilterIsLeftAlone()
    {
        var document = StructureFixtures.File("/Metadata 30 0 R", pdf =>
            pdf.Stream(30, "/Type /Metadata /Subtype /XML /Filter [/Crypt] /DecodeParms [<</Name /Identity>>]", Packet));
        Sample().Write(document);
        Assert.Contains("Old title", Encoding.UTF8.GetString(document.RawData(document.Stream(document.Catalog, "Metadata")!)));
    }

    [Fact]
    public void WorksInAnEncryptedDocument()
    {
        var id = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
        var security = PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes128, id, new Random(5));
        var encrypted = PdfDocument.Open(StructureFixtures.Open().SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id)));
        Sample().Write(encrypted);
        var reopened = PdfDocument.Open(encrypted.SaveIncremental());
        Assert.Equal("Annual report", DocumentMetadata.Read(reopened).Title);
        Assert.Equal("Finance", DocumentMetadata.Read(reopened).Custom["Department"]);
    }
}
