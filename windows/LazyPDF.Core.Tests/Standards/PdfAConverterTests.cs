using System.Security.Cryptography;
using System.Text;
using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfAConverterTests
{
    private static PdfAConversion Convert(byte[] file, PdfALevel level = PdfALevel.A2b, string? password = null) =>
        new PdfAConverter(new SystemFonts()).Convert(file, level, StandardsKit.Date, password);

    private static byte[] Clean(PdfAConversion result)
    {
        Assert.Null(result.Refusal);
        Assert.NotNull(result.Bytes);
        Assert.True(result.Remaining.Count == 0, string.Join("\n", result.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        return result.Bytes;
    }

    private static string PigText(byte[] file)
    {
        using var pig = PigDocument.Open(file);
        return pig.GetPage(1).Text;
    }

    /// <summary>A page showing text in plain Helvetica, as a word processor from long ago would make it; <paramref name="extra"/> adds objects from number 6.</summary>
    private static byte[] Plain(string content = "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET", string catalog = "", string page = "", string resources = "", Action<TestPdf>? extra = null, string trailer = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> {resources}>> {page}>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        extra?.Invoke(pdf);
        return pdf.Finish("/Root 1 0 R " + trailer);
    }

    [Fact]
    public void PlainTextBecomesAPdfA2bFileThatStillReadsTheSame()
    {
        SystemFonts.RequireArial();
        var result = Convert(Plain());
        byte[] file = Clean(result);
        Assert.Contains("Hello world", PigText(file));
        using var document = PdfDocument.Open(file);
        Assert.Equal(2, document.PdfAPart);
        Assert.Equal("B", document.PdfAConformance);
        Assert.Contains(result.Changes, c => c.Contains("embedded"));
        var font = PdfFont.Get(document, (PdfDictionary)document.Resolve(((PdfDictionary)document.Resolve(document.Pages[0].Resources!["Font"])!)["F1"])!);
        Assert.True(font.IsEmbedded);
        Assert.Equal("Hello world", font.ToText("Hello world"u8));
    }

    [Theory]
    [InlineData(PdfALevel.A1b, "%PDF-1.4", 1, "B")]
    [InlineData(PdfALevel.A2b, "%PDF-1.7", 2, "B")]
    [InlineData(PdfALevel.A2u, "%PDF-1.7", 2, "U")]
    [InlineData(PdfALevel.A3b, "%PDF-1.7", 3, "B")]
    [InlineData(PdfALevel.A3u, "%PDF-1.7", 3, "U")]
    [InlineData(PdfALevel.A4, "%PDF-2.0", 4, null)]
    public void EveryLevelConvertsToAFileThatNamesItself(PdfALevel level, string header, int part, string? conformance)
    {
        SystemFonts.RequireArial();
        byte[] file = Clean(Convert(Plain(), level));
        Assert.StartsWith(header, StandardsKit.Latin(file));
        using var document = PdfDocument.Open(file);
        Assert.Equal(part, document.PdfAPart);
        Assert.Equal(conformance, document.PdfAConformance);
        Assert.Contains("Hello world", PigText(file));
    }

    [Fact]
    public void LevelUGetsAToUnicodeMapForItsFonts()
    {
        SystemFonts.RequireArial();
        byte[] file = Clean(Convert(Plain(), PdfALevel.A2u));
        using var document = PdfDocument.Open(file);
        Assert.True(PdfFont.Get(document, (PdfDictionary)document.Resolve(((PdfDictionary)document.Resolve(document.Pages[0].Resources!["Font"])!)["F1"])!).HasToUnicode);
    }

    [Fact]
    public void ConvertingTwiceChangesNothingThatMatters()
    {
        SystemFonts.RequireArial();
        byte[] once = Clean(Convert(Plain()));
        byte[] twice = Clean(Convert(once));
        Assert.Contains("Hello world", PigText(twice));
    }

    [Fact]
    public void Part1RefusesTransparencyAndSaysWhy()
    {
        byte[] file = Plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>");
        var result = Convert(file, PdfALevel.A1b);
        Assert.Null(result.Bytes);
        Assert.Contains("transparency", result.Refusal);
        Assert.Contains("PDF/A-2", result.Refusal);
    }

    [Fact]
    public void Part1DropsAGroupThatNothingOnThePageNeeds()
    {
        SystemFonts.RequireArial();
        var result = Convert(Plain(page: "/Group << /S /Transparency /CS /DeviceRGB >>"), PdfALevel.A1b);
        Clean(result);
        Assert.Contains(result.Changes, c => c.Contains("transparency groups"));
    }

    [Fact]
    public void Part2KeepsTransparency()
    {
        SystemFonts.RequireArial();
        Clean(Convert(Plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>")));
    }

    [Fact]
    public void AFileThatIsNotAPdfOrNeedsAPasswordIsRefused()
    {
        Assert.Contains("could not be read", Convert("not a pdf"u8.ToArray()).Refusal);
        byte[] locked = Lock(Plain(), "user", "owner", PdfPermissions.All);
        Assert.Contains("password", Convert(locked, password: "wrong").Refusal);
    }

    [Fact]
    public void EncryptionIsRemovedWhenTheRightsAreThere()
    {
        SystemFonts.RequireArial();
        byte[] owner = Lock(Plain(), "user", "owner", PdfPermissions.Print);
        byte[] file = Clean(Convert(owner, password: "owner"));
        using var document = PdfDocument.Open(file);
        Assert.False(document.IsEncrypted);
        Assert.Contains("Hello world", PigText(file));

        byte[] open = Lock(Plain(), "user", "owner", PdfPermissions.All);
        Assert.NotNull(Convert(open, password: "user").Bytes);
    }

    [Fact]
    public void AUserWhoMayNotModifyTheFileCannotHaveItConverted()
    {
        byte[] locked = Lock(Plain(), "user", "owner", PdfPermissions.Print);
        var result = Convert(locked, password: "user");
        Assert.Null(result.Bytes);
        Assert.Contains("permissions", result.Refusal);
    }

    [Fact]
    public void ActionsAndScriptsAreRemoved()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(catalog: "/OpenAction << /S /JavaScript /JS (1) >> /AA << /WC << /S /URI /URI (x) >> >> /Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>",
            page: "/Annots [6 0 R 7 0 R]", extra: pdf =>
            {
                pdf.Obj(6, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A << /S /Launch /F (a.exe) /Next << /S /URI /URI (x) >> >>>>");
                pdf.Obj(7, "<</Type /Annot /Subtype /Link /Rect [60 10 90 50] /F 4 /Border [0 0 0] /A << /S /URI /URI (http://example.com/) >>>>");
            });
        var result = Convert(file);
        byte[] bytes = Clean(result);
        using var document = PdfDocument.Open(bytes);
        Assert.False(PdfActions.HasJavaScript(document));
        Assert.Contains(result.Changes, c => c.Contains("actions or scripts"));
        var links = PdfLinks.Read(document, document.Pages[0]);
        Assert.Contains(links, l => l.Uri == "http://example.com/");
    }

    [Fact]
    public void ForbiddenAnnotationsGoAndTheOthersAreMadeVisibleWithAnAppearance()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(page: "/Annots [6 0 R 7 0 R 8 0 R]", extra: pdf =>
        {
            pdf.Obj(6, "<</Type /Annot /Subtype /Sound /Rect [10 10 50 50] /F 4>>");
            pdf.Obj(7, "<</Type /Annot /Subtype /Square /Rect [60 10 90 50] /F 2 /C [1 0 0]>>");
            pdf.Obj(8, "<</Type /Annot /Subtype /Square /Rect [100 10 140 50] /C [0 0 1] /AP << /N 9 0 R /D 9 0 R >>>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 RG 0 0 40 40 re S");
        });
        byte[] bytes = Clean(Convert(file));
        using var document = PdfDocument.Open(bytes);
        var annotations = PdfAnnotations.Read(document, document.Pages[0]);
        Assert.Equal(2, annotations.Count);
        Assert.All(annotations, a => Assert.True(a.HasAppearance));
        Assert.All(annotations, a => Assert.Equal(AnnotationFlags.Print, a.Flags));
    }

    [Fact]
    public void AFormGetsItsAppearancesAndLosesNeedAppearancesAndXfa()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(catalog: "/AcroForm << /Fields [6 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> /XFA [(a) 4 0 R] >>",
            page: "/Annots [6 0 R]", extra: pdf => pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (abc) /Rect [10 10 100 30] /F 4>>"));
        byte[] bytes = Clean(Convert(file));
        using var document = PdfDocument.Open(bytes);
        var form = PdfForm.Read(document);
        Assert.False(form.NeedAppearances);
        Assert.False(document.HasXfa);
        Assert.Equal("abc", form.Find("name")!.Value);
        Assert.True(PdfAnnotations.Read(document, document.Pages[0]).Single().HasAppearance);
    }

    [Fact]
    public void LzwStreamsAreRewrittenWithFlate()
    {
        SystemFonts.RequireArial();
        byte[] lzw = PdfFilterEncoders.Lzw("BT /F1 12 Tf 20 100 Td (Hello world) Tj ET"u8);
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "/Filter /LZWDecode", lzw);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        var result = Convert(pdf.Finish("/Root 1 0 R"));
        byte[] bytes = Clean(result);
        Assert.Contains("Hello world", PigText(bytes));
        Assert.Contains(result.Changes, c => c.Contains("LZW"));
    }

    [Fact]
    public void ImageAndFormKeysThatAreNotAllowedAreRemoved()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain("q 10 0 0 10 0 0 cm /Im Do Q /Fm Do", resources: "/XObject << /Im 6 0 R /Fm 7 0 R >>", extra: pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate true /OPI << >> /Alternates []", new byte[] { 0 });
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Ref << /F (x.pdf) /Page 0 >> /OPI << >>", "0 g 0 0 5 5 re f");
        });
        Clean(Convert(file));
    }

    [Fact]
    public void LayersAreKeptFromPart2AndDroppedInPart1()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(catalog: "/OCProperties << /OCGs [6 0 R] /D << /Order [] /AS [<< /Event /View >>] >> >>", extra: pdf => pdf.Obj(6, "<</Type /OCG /Name (L)>>"));
        using (var kept = PdfDocument.Open(Clean(Convert(file))))
        {
            Assert.Single(PdfLayers.Read(kept).Layers);
        }
        using var dropped = PdfDocument.Open(Clean(Convert(file, PdfALevel.A1b)));
        Assert.Empty(PdfLayers.Read(dropped).Layers);
    }

    [Fact]
    public void EmbeddedFilesGoInPart1AndGetTheirRelationshipInPart3()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 6 0 R] >> >>", extra: pdf =>
        {
            pdf.Obj(6, "<</Type /Filespec /F (a.dat) /EF << /F 7 0 R >>>>");
            pdf.Stream(7, "/Type /EmbeddedFile", "hello");
        });
        Clean(Convert(file, PdfALevel.A1b));
        using var three = PdfDocument.Open(Clean(Convert(file, PdfALevel.A3b)));
        Assert.Single(PdfAttachments.List(three));
        using var two = PdfDocument.Open(Clean(Convert(file)));
        Assert.Empty(PdfAttachments.List(two));
    }

    [Fact]
    public void InfoAndXmpAgreeAndKeepTheTextAsWritten()
    {
        SystemFonts.RequireArial();
        string title = "Ünïcode \"&\" <b>";
        string hex = "FEFF" + string.Concat(title.Select(c => ((int)c).ToString("X4")));
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        pdf.Obj(3, $"<</Title <{hex}> /Author (A & B) /Keywords (one, two) /Producer (Old Tool) /CreationDate (D:20200102030405+03'00')>>");
        byte[] bytes = Clean(Convert(pdf.Finish("/Root 1 0 R /Info 3 0 R")));
        using var document = PdfDocument.Open(bytes);
        var meta = DocumentMetadata.Read(document);
        Assert.Equal(title, meta.Title);
        Assert.Equal("A & B", meta.Author);
        Assert.Equal("Old Tool", meta.Producer);
        Assert.Equal(new DateTimeOffset(2020, 1, 2, 3, 4, 5, TimeSpan.FromHours(3)), meta.Created);
        Assert.Equal(StandardsKit.Date, meta.Modified);
    }

    [Fact]
    public void Part4KeepsOnlyTheDatesInInfo()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(trailer: "/Info 6 0 R", extra: pdf => pdf.Obj(6, "<</Title (T) /Author (A) /Producer (P)>>"));
        using var document = PdfDocument.Open(Clean(Convert(file, PdfALevel.A4)));
        Assert.Equal(["CreationDate", "ModDate"], document.Info!.Entries.Select(e => e.Key).Order().ToArray());
        Assert.Equal("T", DocumentMetadata.Read(document).Title);
    }

    [Fact]
    public void ACmykFileWithoutACmykIntentIsReturnedWithWhatRemains()
    {
        SystemFonts.RequireArial();
        var result = Convert(Plain("0 0 0 1 k 0 0 50 50 re f"));
        Assert.NotNull(result.Bytes);
        Assert.Contains(result.Remaining, i => i.Clause == "6.2.4.3" && i.Message.Contains("DeviceCMYK"));
    }

    [Fact]
    public void AnExistingIccOutputIntentIsKept()
    {
        SystemFonts.RequireArial();
        byte[] file = Plain(catalog: "/OutputIntents [6 0 R]", extra: pdf =>
        {
            pdf.Obj(6, "<</Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (mine) /DestOutputProfile 7 0 R>>");
            pdf.Stream(7, "/N 3", PdfASrgb.SrgbProfile);
        });
        var result = Convert(file);
        byte[] bytes = Clean(result);
        Assert.DoesNotContain(result.Changes, c => c.Contains("sRGB output intent"));
        using var document = PdfDocument.Open(bytes);
        var intent = (PdfDictionary)document.Resolve(document.Array(document.Catalog, "OutputIntents")!.Items[0])!;
        Assert.Equal("GTS_PDFA1", document.Name(intent, "S"));
    }

    [Fact]
    public void TheProfileIsTheOneFromLazyScan()
    {
        Assert.Equal(736, PdfASrgb.SrgbProfile.Length);
        Assert.Equal("af4efe28f6d311799865f325ba39184a2e978b113ca74124d60af7de22b105f4", System.Convert.ToHexStringLower(SHA256.HashData(PdfASrgb.SrgbProfile)));
    }

    [Fact]
    public void TheOutputOpensInPdfPigAndTheValidatorAgreesWithTheConversion()
    {
        SystemFonts.RequireArial();
        var result = Convert(Plain());
        Assert.Contains("Hello", PigText(Clean(result)));
        using var again = PdfDocument.Open(result.Bytes!);
        Assert.Empty(PdfAValidator.Validate(again, PdfALevel.A2b).Issues);
    }

    private static byte[] Lock(byte[] file, string user, string owner, PdfPermissions permissions)
    {
        var id = RandomNumberGenerator.GetBytes(16);
        using var document = PdfDocument.Open(file);
        var security = PdfSecurity.Create(user, owner, permissions, PdfCryptStrength.Aes256, id);
        return document.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));
    }
}
