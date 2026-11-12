using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XmlTreeTests
{
    private static XmlElement Read(string xml, XmlLimits? limits = null) => XmlTree.Parse(Encoding.UTF8.GetBytes(xml), limits);

    [Fact]
    public void GoldenFile()
    {
        Golden.Check("xml", "xml-output.txt", XmlTreeGolden.Run(Golden.Input("xml", "xml-input.txt")));
    }

    [Fact]
    public void ReadsWordProcessingNamespaces()
    {
        const string W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        var doc = Read($"<w:document xmlns:w=\"{W}\"><w:body><w:p><w:r><w:t xml:space=\"preserve\"> a </w:t></w:r><w:r><w:t>b</w:t></w:r></w:p></w:body></w:document>");
        var runs = doc.Child(W, "body")!.Child(W, "p")!.Elements(W, "r").ToList();
        Assert.Equal(2, runs.Count);
        Assert.Equal(" a ", runs[0].Child(W, "t")!.Text);
        Assert.Equal("preserve", runs[0].Child(W, "t")!.Attribute("http://www.w3.org/XML/1998/namespace", "space"));
        Assert.Null(doc.Child("", "body"));
    }

    [Fact]
    public void AttributeWithoutPrefixHasNoNamespace()
    {
        var e = Read("<a xmlns=\"urn:d\" x=\"1\"/>");
        Assert.Equal("urn:d", e.Uri);
        Assert.Equal("1", e.Attribute("x"));
        Assert.Null(e.Attribute("urn:d", "x"));
    }

    [Fact]
    public void ExternalEntityIsRefusedNotFetched()
    {
        var ex = Assert.Throws<PdfReadException>(() => Read("<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///c:/windows/win.ini\">]><a>&x;</a>"));
        Assert.Equal(PdfReadProblem.Unsupported, ex.Problem);
    }

    [Fact]
    public void BillionLaughsIsRefusedAtTheDoctype()
    {
        var ex = Assert.Throws<PdfReadException>(() => Read("<!DOCTYPE l [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><l>&b;&b;</l>"));
        Assert.Equal(PdfReadProblem.Unsupported, ex.Problem);
    }

    [Fact]
    public void DeepNestingIsRefusedWithoutOverflow()
    {
        string xml = string.Concat(Enumerable.Repeat("<a>", 200_000));
        var ex = Assert.Throws<PdfReadException>(() => Read(xml));
        Assert.Equal(PdfReadProblem.Unsupported, ex.Problem);
    }

    [Fact]
    public void DepthAtTheLimitReads()
    {
        var limits = new XmlLimits(MaxDepth: 1000);
        string xml = string.Concat(Enumerable.Repeat("<a>", 1000)) + string.Concat(Enumerable.Repeat("</a>", 1000));
        var e = Read(xml, limits);
        int depth = 1;
        for (XmlElement? next = e.Elements().FirstOrDefault(); next is not null; next = next.Elements().FirstOrDefault()) depth++;
        Assert.Equal(1000, depth);
    }

    [Fact]
    public void ManyElementsAreRefused()
    {
        string xml = "<a>" + string.Concat(Enumerable.Repeat("<b/>", 1_000)) + "</a>";
        var ex = Assert.Throws<PdfReadException>(() => Read(xml, new XmlLimits(MaxElements: 999)));
        Assert.Equal(PdfReadProblem.Unsupported, ex.Problem);
        Assert.Equal(1000, Read(xml, new XmlLimits(MaxElements: 1001)).Elements().Count());
    }

    [Fact]
    public void ManyAttributesAreRefused()
    {
        string xml = "<a " + string.Join(" ", Enumerable.Range(0, 5000).Select(i => $"x{i}=\"1\"")) + "/>";
        var ex = Assert.Throws<PdfReadException>(() => Read(xml));
        Assert.Equal(PdfReadProblem.Unsupported, ex.Problem);
    }

    [Fact]
    public void RunOfAmpersandsIsFast()
    {
        string xml = "<a>" + new string('&', 200_000) + "</a>";
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.Throws<PdfReadException>(() => Read(xml));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public void LargeTextReadsInOneNode()
    {
        string text = new('x', 5_000_000);
        var e = Read($"<a>{text}<!-- c -->{text}</a>");
        Assert.Single(e.Children);
        Assert.Equal(10_000_000, e.Text.Length);
    }

    [Fact]
    public void RandomBytesNeverCrash()
    {
        var rng = new Random(7);
        byte[] seed = Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?><a xmlns:p=\"urn:p\" p:x=\"&amp;\"><p:b>t&#65;<![CDATA[c]]></p:b><!-- c --></a>");
        for (int n = 0; n < 3000; n++)
        {
            byte[] d = (byte[])seed.Clone();
            for (int k = rng.Next(1, 5); k > 0; k--) d[rng.Next(d.Length)] = (byte)rng.Next(256);
            if (n % 3 == 0) d = d[..rng.Next(d.Length)];
            try
            {
                XmlTree.Parse(d);
            }
            catch (PdfReadException)
            {
            }
        }
    }
}
