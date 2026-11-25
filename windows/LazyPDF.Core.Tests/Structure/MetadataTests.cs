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
    public void NoXmpIsNotUnreadable() => Assert.False(DocumentMetadata.Read(StructureFixtures.Open()).XmpUnreadable);

    [Fact]
    public void ReadableXmpIsNotUnreadable() => Assert.False(DocumentMetadata.Read(WithXmp(Packet)).XmpUnreadable);

    [Theory]
    [InlineData("this is not xml <<<")]
    [InlineData("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><nothing/></x:xmpmeta>")]
    [InlineData("TOO BIG")]
    public void XmpThatCannotBeReadIsReported(string xml)
    {
        if (xml == "TOO BIG") xml = "<x/>" + new string(' ', (1 << 24) + 1);
        var document = WithXmp(xml, info: "<</Title (From info)>>");
        document.Trailer["Info"] = new PdfReference(31, 0);
        var read = DocumentMetadata.Read(document);
        Assert.True(read.XmpUnreadable);
        Assert.Equal("From info", read.Title);
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

    private const string Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    private const string DcNs = "http://purl.org/dc/elements/1.1/";

    private static PdfDocument WithBytes(byte[] packet) =>
        StructureFixtures.File("/Metadata 30 0 R", pdf => pdf.Stream(30, "/Type /Metadata /Subtype /XML", packet));

    private static string PacketText(PdfDocument document) =>
        Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!)).Replace("\r\n", "\n");

    [Fact]
    public void CharactersXmlForbidsAreLeftOutOfXmp()
    {
        var document = WithXmp(Packet);
        (Sample() with { Title = "A\u0001B￾", Subject = "a\r\nb\rc", Keywords = "k\u0008;m" }).Write(document);
        string text = PacketText(document);
        Assert.Contains(">AB</rdf:li>", text);
        Assert.Contains(">a\nb\nc</rdf:li>", text);
        Assert.Contains("<rdf:li>k</rdf:li><rdf:li>m</rdf:li>", text);
        Assert.NotNull(XmpPacket.Load(document));
    }

    [Fact]
    public void PacketThatIsNotUtf8IsLeftAlone()
    {
        byte[] latin1 = Encoding.Latin1.GetBytes($"<rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns:dc=\"{DcNs}\"><dc:title>café</dc:title></rdf:Description></rdf:RDF>");
        var document = WithBytes(latin1);
        Assert.Null(DocumentMetadata.Read(document).Title);
        Sample().Write(document);
        Assert.Equal(latin1, document.Data(document.Stream(document.Catalog, "Metadata")!));
    }

    [Fact]
    public void XmpIsReadInTheEncodingsXmlReaderKnows()
    {
        string body = $"<rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns:dc=\"{DcNs}\"><dc:title>café</dc:title></rdf:Description></rdf:RDF>";
        string Declared(string name) => $"<?xml version=\"1.0\" encoding=\"{name}\"?>";
        var utf32be = Encoding.GetEncoding(12001);
        (string Name, byte[] Bytes, string Title)[] cases =
        [
            ("utf-16le", Encoding.Unicode.GetBytes(body), "café"),
            ("utf-16le mark", [.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes(body)], "café"),
            ("utf-16be", Encoding.BigEndianUnicode.GetBytes(body), "café"),
            ("utf-16 declared", Encoding.Unicode.GetBytes(Declared("utf-16") + body), "café"),
            ("utf-32le mark", [.. Encoding.UTF32.GetPreamble(), .. Encoding.UTF32.GetBytes(body)], "café"),
            ("utf-32be", utf32be.GetBytes(body), "café"),
            ("utf-32be mark", [.. utf32be.GetPreamble(), .. utf32be.GetBytes(body)], "café"),
            ("latin-1 declared", Encoding.Latin1.GetBytes(Declared("ISO-8859-1") + body), "café"),
            ("ascii declared", Encoding.Latin1.GetBytes(Declared("ascii") + body), "caf?"),
            ("utf-8 mark and latin-1 declared", [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(Declared("latin1") + body)], "cafÃ©"),
        ];
        foreach (var (name, bytes, title) in cases)
        {
            Assert.True(title == DocumentMetadata.Read(WithBytes(bytes)).Title, name);
        }
    }

    [Fact]
    public void XmpInAnEncodingXmlReaderRefusesIsLeftAlone()
    {
        string body = $"<rdf:RDF xmlns:rdf=\"{Rdf}\"/>";
        byte[][] cases =
        [
            Encoding.Unicode.GetBytes($"<?xml version=\"1.0\" encoding=\"utf-8\"?>{body}"),
            Encoding.UTF8.GetBytes($"<?xml version=\"1.0\" encoding=\"utf-16\"?>{body}"),
            Encoding.Latin1.GetBytes($"<?xml version=\"1.0\" encoding=\"no-such-encoding\"?>{body}"),
            [.. Encoding.UTF8.GetBytes("<rdf:RDF xmlns:rdf=\"" + Rdf + "\">a"), 0xED, 0xA0, 0x80, .. Encoding.UTF8.GetBytes("</rdf:RDF>")],
            [0xFF, 0xFE, .. Encoding.Unicode.GetBytes("<rdf:RDF xmlns:rdf=\"" + Rdf + "\">a"), 0x00, 0xD8, .. Encoding.Unicode.GetBytes("</rdf:RDF>")],
        ];
        foreach (byte[] bytes in cases)
        {
            var document = WithBytes(bytes);
            Sample().Write(document);
            Assert.Equal(bytes, document.Data(document.Stream(document.Catalog, "Metadata")!));
        }
    }

    [Fact]
    public void XmpThatXmlReaderRefusesIsLeftAlone()
    {
        string[] cases =
        [
            $"<?xml foo=\"1\" version=\"1.0\"?><rdf:RDF xmlns:rdf=\"{Rdf}\"/>",
            $"<?xml version=\"1.0\" standalone=\"yes\" encoding=\"utf-8\"?><rdf:RDF xmlns:rdf=\"{Rdf}\"/>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\" xmlns=\"http://www.w3.org/2000/xmlns/\"/>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\"><Ĳ/></rdf:RDF>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\"><é></é></rdf:RDF>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\">&#X41;</rdf:RDF>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\">&#x110000;</rdf:RDF>",
        ];
        foreach (string xml in cases)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(xml);
            var document = WithBytes(bytes);
            Sample().Write(document);
            Assert.True(bytes.AsSpan().SequenceEqual(document.Data(document.Stream(document.Catalog, "Metadata")!)), xml);
        }
    }

    [Fact]
    public void XmpThatXmlReaderAcceptsIsRead()
    {
        string[] cases =
        [
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns:dc=\"{DcNs}\"><dc:title>&#x0000000000041;</dc:title></rdf:Description></rdf:RDF>",
            $"<rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns:dc=\"{DcNs}\" é=\"1\" é=\"2\"><dc:title>A</dc:title></rdf:Description></rdf:RDF>",
            $"<?xml version=\"1.0\" standalone=\"no\"?><rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns:dc=\"{DcNs}\"><dc:title>A</dc:title></rdf:Description></rdf:RDF>",
        ];
        foreach (string xml in cases)
        {
            Assert.True("A" == DocumentMetadata.Read(WithBytes(Encoding.UTF8.GetBytes(xml))).Title, xml);
        }
    }

    [Fact]
    public void NamesXmlConvertRefusesAreNotCustomKeys()
    {
        var document = WithXmp(Packet);
        (Sample() with { Custom = new Dictionary<string, string> { ["Ĳ"] = "x", ["Fine"] = "y" } }).Write(document);
        string text = PacketText(document);
        Assert.DoesNotContain("Ĳ", text);
        Assert.Contains(">y</pdfx:Fine>", text);
    }

    [Fact]
    public void PrefixesAreChosenAgainWhenThePacketIsWritten()
    {
        var twice = WithXmp($"<a:RDF xmlns:a=\"{Rdf}\" xmlns:b=\"{Rdf}\"><a:Description/></a:RDF>");
        Sample().Write(twice);
        string text = PacketText(twice);
        Assert.Contains("<b:RDF ", text);
        Assert.Contains("<b:Description ", text);

        var byDefault = WithXmp($"<rdf:RDF xmlns:rdf=\"{Rdf}\"><rdf:Description xmlns=\"{DcNs}\"/></rdf:RDF>");
        Sample().Write(byDefault);
        text = PacketText(byDefault);
        Assert.Contains("xmlns:dc=", text);
        Assert.Contains("<dc:title>", text);
        Assert.NotNull(XmpPacket.Load(byDefault));
    }

    [Fact]
    public void AttributeInTheOnlyDefaultNamespaceGetsAPrefix()
    {
        var document = WithXmp($"<RDF xmlns=\"{Rdf}\"/>");
        Sample().Write(document);
        Assert.NotNull(XmpPacket.Load(document));
        Assert.Contains("<Description p", PacketText(document));
    }
}
