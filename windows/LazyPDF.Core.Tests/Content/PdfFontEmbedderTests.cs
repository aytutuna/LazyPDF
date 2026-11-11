using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfFontEmbedderTests
{
    private sealed class WindowsFonts : IFontSource
    {
        public List<(string Family, FontStyles Style)> Requests { get; } = [];

        public FontFile? Find(string family, FontStyles style)
        {
            Requests.Add((family, style));
            string name = (style.HasFlag(FontStyles.Bold), style.HasFlag(FontStyles.Italic)) switch
            {
                (true, true) => "arialbi.ttf",
                (true, false) => "arialbd.ttf",
                (false, true) => "ariali.ttf",
                _ => "arial.ttf",
            };
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), name);
            Assert.True(File.Exists(path), $"{name} is not installed; these tests need it");
            return new FontFile(File.ReadAllBytes(path));
        }
    }

    private sealed class NoFonts : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) => null;
    }

    private const string Turkish = "Çok güzel şiir: ığüşöç İĞÜŞÖÇ";

    private static PdfDocument Blank() => PdfDocument.Open(TestPdf.Simple(1));

    private static byte[] Draw(PdfDocument document, PdfDrawFont font, string text, double size)
    {
        var page = document.Pages[0];
        var resources = ContentResources.ForEdit(document, page);
        string name = ContentResources.Add(document, resources, "Font", font.Reference, "F");
        var content = new ContentWriter().BeginText().Font(name, size).MoveText(50, 700).Show(font.Encode(text)).EndText();
        var stream = new PdfStream(new PdfDictionary(), content.ToArray());
        page.Dictionary["Contents"] = document.Add(stream);
        return document.SaveRewrite();
    }

    private static string PigText(byte[] file)
    {
        using var pig = PigDocument.Open(file);
        return pig.GetPage(1).Text;
    }

    [Fact]
    public void WinAnsiTextUsesAStandardFont()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Regular, ["Hello, World (café)"])!;
        Assert.False(font.IsEmbedded);
        var dictionary = (PdfDictionary)document.Resolve(font.Reference)!;
        Assert.Equal("Helvetica", ((PdfName)dictionary["BaseFont"]!).Value);
        Assert.Equal("WinAnsiEncoding", ((PdfName)dictionary["Encoding"]!).Value);
        Assert.Equal(0xE9, font.Encode("é")[0]);
        Assert.Equal((722 + 556 + 222 + 222 + 556) * 10 / 1000.0, font.Width("Hello", 10), 6);
    }

    [Fact]
    public void ArialAndStyleMapToTheStandardNames()
    {
        var document = Blank();
        var embedder = new PdfFontEmbedder(document);
        string Base(string family, FontStyles style)
        {
            var f = embedder.Add(family, style, ["x"])!;
            return ((PdfName)((PdfDictionary)document.Resolve(f.Reference)!)["BaseFont"]!).Value;
        }
        Assert.Equal("Helvetica-Bold", Base("Arial", FontStyles.Bold));
        Assert.Equal("Helvetica-BoldOblique", Base("Helvetica", FontStyles.Bold | FontStyles.Italic));
        Assert.Equal("Times-Italic", Base("Times New Roman", FontStyles.Italic));
        Assert.Equal("Courier", Base("Courier New", FontStyles.Regular));
    }

    [Fact]
    public void TurkishTextNeedsAFontFile()
    {
        var document = Blank();
        Assert.Null(new PdfFontEmbedder(document).Add("Arial", FontStyles.Regular, [Turkish]));
        Assert.Null(new PdfFontEmbedder(document, new NoFonts()).Add("Arial", FontStyles.Regular, [Turkish]));
        Assert.Null(new PdfFontEmbedder(document, new NoFonts()).Add("Whatever", FontStyles.Regular, ["abc"]));
    }

    [Fact]
    public void TurkishTextIsEmbeddedAndReadBackByPdfPigAndUs()
    {
        var document = Blank();
        var source = new WindowsFonts();
        var font = new PdfFontEmbedder(document, source).Add("Arial", FontStyles.Regular, [Turkish])!;
        Assert.True(font.IsEmbedded);
        Assert.Empty(font.Missing);
        Assert.Equal([("Arial", FontStyles.Regular)], source.Requests);

        var file = Draw(document, font, Turkish, 14);
        Assert.Equal(Turkish, PigText(file));

        using var reopened = PdfDocument.Open(file);
        var fonts = reopened.Dict(reopened.Pages[0].Resources, "Font")!;
        var dictionary = (PdfDictionary)reopened.Resolve(fonts.Entries[0].Value)!;
        var ours = PdfFont.Get(reopened, dictionary);
        Assert.True(ours.IsComposite);
        Assert.Equal(Turkish, ours.ToText(font.Encode(Turkish)));
        var recorder = ContentTestPdf.Run(reopened);
        Assert.Equal(Turkish, recorder.Text);
    }

    [Fact]
    public void TheEmbeddedFontIsASubsetWithTheUsualPieces()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document, new WindowsFonts()).Add("Arial", FontStyles.Regular, ["ğiş"], embed: true)!;
        var type0 = (PdfDictionary)document.Resolve(font.Reference)!;
        Assert.Equal("Type0", ((PdfName)type0["Subtype"]!).Value);
        Assert.Equal("Identity-H", ((PdfName)type0["Encoding"]!).Value);
        Assert.IsType<PdfStream>(document.Resolve(type0["ToUnicode"]));
        var cid = (PdfDictionary)document.Resolve(((PdfArray)document.Resolve(type0["DescendantFonts"])!).Items[0])!;
        Assert.Equal("CIDFontType2", ((PdfName)cid["Subtype"]!).Value);
        Assert.IsType<PdfArray>(document.Resolve(cid["W"]));
        var descriptor = (PdfDictionary)document.Resolve(cid["FontDescriptor"])!;
        var program = (PdfStream)document.Resolve(descriptor["FontFile2"])!;
        Assert.True(document.Data(program).Length < 20_000);
        Assert.Matches("^[A-Z]{6}\\+", ((PdfName)type0["BaseFont"]!).Value);
    }

    [Fact]
    public void IncrementalSaveReopensToo()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document, new WindowsFonts()).Add("Arial", FontStyles.Bold, ["İstanbul şehri"])!;
        var page = document.Pages[0];
        var resources = ContentResources.ForEdit(document, page);
        string name = ContentResources.Add(document, resources, "Font", font.Reference, "F");
        var content = new ContentWriter().BeginText().Font(name, 12).MoveText(10, 10).Show(font.Encode("İstanbul şehri")).EndText();
        page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), content.ToArray()));
        var file = document.SaveIncremental();
        Assert.Equal("İstanbul şehri", PigText(file));
        using var reopened = PdfDocument.Open(file);
        Assert.Empty(reopened.Repairs);
    }

    [Fact]
    public void CharactersTheFontLacksAreListed()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document, new WindowsFonts()).Add("Arial", FontStyles.Regular, ["a中b"], embed: true)!;
        Assert.Equal([0x4E2D], font.Missing);
    }

    private sealed class CjkViaArial(bool covering) : IFontSource
    {
        public FontFile? Find(string family, FontStyles style)
        {
            string fonts = Environment.GetFolderPath(Environment.SpecialFolder.Fonts);
            if (family == "Arial" && covering) return new FontFile(File.ReadAllBytes(Path.Combine(fonts, "msyh.ttc")));
            return family is "Foo" or "Arial" ? new FontFile(File.ReadAllBytes(Path.Combine(fonts, "arial.ttf"))) : null;
        }
    }

    private static int Type0Count(PdfDocument document) =>
        document.ObjectNumbers.Count(n => document.Get(n) is PdfDictionary d && document.Name(d, "Subtype") == "Type0");

    [Fact]
    public void AddCoveringFallsBackToAFontThatHasTheCharacters()
    {
        var document = Blank();
        int before = Type0Count(document), objects = document.ObjectNumbers.Count;
        var font = new PdfFontEmbedder(document, new CjkViaArial(covering: true)).AddCovering("Foo", FontStyles.Regular, ["a中"])!;
        Assert.Empty(font.Missing);
        Assert.Equal(before + 1, Type0Count(document));
        Assert.Contains("YaHei", ((PdfName)((PdfDictionary)document.Resolve(font.Reference)!)["BaseFont"]!).Value);
        Assert.True(document.ObjectNumbers.Count - objects < 12, "only the chosen font is added");
    }

    [Fact]
    public void AddCoveringWithNothingCoveringKeepsTheLeastMissing()
    {
        var document = Blank();
        int before = Type0Count(document);
        var font = new PdfFontEmbedder(document, new CjkViaArial(covering: false)).AddCovering("Foo", FontStyles.Regular, ["a中"])!;
        Assert.Equal([0x4E2D], font.Missing);
        Assert.Equal(before + 1, Type0Count(document));
    }

    [Fact]
    public void AddCoveringKeepsTheStandardFontForTextThatFits()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document, new CjkViaArial(covering: true)).AddCovering("Arial", FontStyles.Regular, ["Hello"])!;
        Assert.False(font.IsEmbedded);
    }

    [Fact]
    public void EachCallAddsItsOwnFont()
    {
        var document = Blank();
        var embedder = new PdfFontEmbedder(document, new WindowsFonts());
        var a = embedder.Add("Arial", FontStyles.Regular, ["abc"], embed: true)!;
        var b = embedder.Add("Arial", FontStyles.Regular, ["xyz ğ"], embed: true)!;
        Assert.NotEqual(a.Reference, b.Reference);
    }

    [Fact]
    public void NotAFontFileGivesNull()
    {
        var document = Blank();
        var junk = new JunkFonts();
        Assert.Null(new PdfFontEmbedder(document, junk).Add("X", FontStyles.Regular, ["ğ"]));
    }

    private sealed class JunkFonts : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) => new([1, 2, 3, 4, 5, 6, 7, 8]);
    }

    [Fact]
    public void WidthOfEmbeddedTextMatchesTheFontProgram()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document, new WindowsFonts()).Add("Arial", FontStyles.Regular, ["Hello"], embed: true)!;
        // Arial: H 1479, e 1139, l 455, l 455, o 1139 of 2048.
        Assert.Equal((1479 + 1139 + 455 + 455 + 1139) / 2048.0 * 10, font.Width("Hello", 10), 2);
        Assert.Equal(0, font.Width("", 10));
    }

    [Fact]
    public void WrapBreaksAtSpacesNewlinesAndLongWords()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document).Add("Courier", FontStyles.Regular, ["x"])!;
        // Courier is 600 wide: at size 10 a character is 6 points.
        Assert.Equal(["aaa bbb", "ccc"], font.Wrap("aaa bbb ccc", 10, 45));
        Assert.Equal(["ab", "cd"], font.Wrap("ab\ncd", 10, 1000));
        Assert.Equal(["abcd", "efgh", "ij"], font.Wrap("abcdefghij", 10, 25));
        Assert.Equal([""], font.Wrap("", 10, 100));
        Assert.Equal(["a", "", "b"], font.Wrap("a\n\nb", 10, 100));
        Assert.All(font.Wrap("the quick brown fox jumps over the lazy dog", 10, 100), l => Assert.True(font.Width(l, 10) <= 100));
    }

    [Fact]
    public void LineHeightFollowsTheMetrics()
    {
        var document = Blank();
        var font = new PdfFontEmbedder(document).Add("Helvetica", FontStyles.Regular, ["x"])!;
        Assert.True(font.LineHeight(10) is > 10 and < 20);
        Assert.True(font.Ascent > 0 && font.Descent < 0);
    }

    [Fact]
    public void NoBreakSpaceAndSoftHyphenFitWinAnsi()
    {
        var document = Blank();
        Assert.NotNull(new PdfFontEmbedder(document, new NoFonts()).Add("Helvetica", FontStyles.Regular, ["10 km ­x"]));
    }
}
