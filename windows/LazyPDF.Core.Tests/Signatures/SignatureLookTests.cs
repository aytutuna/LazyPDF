using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureLookTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly byte[] Jpeg = Convert.FromBase64String(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19i" +
        "Z2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2Nj" +
        "Y2NjY2NjY2P/wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF" +
        "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW" +
        "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi" +
        "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC" +
        "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm" +
        "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq" +
        "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDHrPoortyj7fy/U9HNPsfP9D//2Q==");

    private static readonly IReadOnlyList<IReadOnlyList<(double X, double Y)>> Scribble = [[(0, 0), (0.5, 1), (1, 0.2)], [(0.2, 0.5), (0.8, 0.5)]];

    private sealed class Seen : ContentVisitor
    {
        public StringBuilder Text { get; } = new();
        public int Paths { get; private set; }
        public int Images { get; private set; }
        public List<ImageInfo> Painted { get; } = [];
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => Text.Append(glyph.Unicode);
        public override void PaintPath(ContentContext context, PathInfo path) => Paths++;
        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            Images++;
            Painted.Add(image);
        }
    }

    private static PdfStream Appearance(PdfDocument document, string field = "Signature1")
    {
        var widget = PdfForm.Read(document).Find(field)!.Widgets[0];
        return document.Stream(document.Dict(widget.Dictionary, "AP"), "N")!;
    }

    private static Seen Play(byte[] file, string field = "Signature1")
    {
        var document = PdfDocument.Open(file);
        var seen = new Seen();
        new ContentInterpreter(document).Run(Appearance(document, field), seen);
        return seen;
    }

    private static bool HasImageObject(byte[] file) => Regex.IsMatch(SignatureKit.Text(file), @"/Subtype\s*/Image");

    private static PdfDictionary? Resources(byte[] file)
    {
        var document = PdfDocument.Open(file);
        return document.Dict(Appearance(document).Dictionary, "Resources");
    }

    private static bool UsesFont(byte[] file) => Resources(file) is { } resources && resources.ContainsKey("Font");

    private static byte[] Sign(PdfRect rect, SignatureLook look, byte[]? file = null, int rotate = 0)
    {
        file ??= SignatureKit.Plain();
        if (rotate != 0)
        {
            var document = PdfDocument.Open(file);
            document.Pages[0].Dictionary["Rotate"] = new PdfNumber(rotate);
            file = document.SaveIncremental();
        }
        byte[] signed = PdfSigner.Sign(file, SignatureKit.Request(Pki) with { Rect = rect, Look = look });
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
        return signed;
    }

    private static PdfSignRequest Second(PdfRect rect) => new(Pki.LeafEc, Pki.Signing.AddDays(1))
    {
        Chain = Pki.Chain,
        Rect = rect,
        Look = new SignatureLook { Jpeg = Jpeg },
    };

    private static readonly PdfRgbaImage Rgba = new(16, 8, Enumerable.Repeat((byte)200, 16 * 8 * 4).ToArray());

    public static TheoryData<string> Pictures => new() { "jpeg", "ink", "image" };

    private static SignatureLook Graphic(string kind, string? text = null) => kind switch
    {
        "jpeg" => new SignatureLook { Jpeg = Jpeg, Text = text },
        "image" => new SignatureLook { Image = Rgba, Text = text },
        _ => new SignatureLook { Ink = Scribble, Text = text },
    };

    [Theory]
    [MemberData(nameof(Pictures))]
    public void A_box_too_short_for_the_margins_shows_neither_picture_nor_text(string kind)
    {
        byte[] signed = Sign(new PdfRect(20, 20, 240, 25), Graphic(kind));

        Assert.False(HasImageObject(signed));
        var seen = Play(signed);
        Assert.Equal(0, seen.Images);
        Assert.Equal(0, seen.Paths);
        Assert.Equal("", seen.Text.ToString());
        Assert.False(UsesFont(signed));
    }

    [Theory]
    [MemberData(nameof(Pictures))]
    public void A_field_too_narrow_for_the_picture_gives_the_text_the_whole_width(string kind)
    {
        byte[] signed = Sign(new PdfRect(20, 20, 32, 120), Graphic(kind));

        Assert.False(HasImageObject(signed));
        var seen = Play(signed);
        Assert.Equal(0, seen.Images);
        Assert.Equal(0, seen.Paths);
        Assert.NotEqual("", seen.Text.ToString());
    }

    [Theory]
    [MemberData(nameof(Pictures))]
    public void Picture_only_into_a_field_with_no_room_is_a_blank_form(string kind)
    {
        byte[] signed = Sign(new PdfRect(20, 20, 40, 25), Graphic(kind, ""));

        Assert.False(HasImageObject(signed));
        Assert.False(UsesFont(signed));
        Assert.False(Resources(signed)?.ContainsKey("XObject") ?? false);
        var seen = Play(signed);
        Assert.Equal(0, seen.Images + seen.Paths);
    }

    [Fact]
    public void A_short_box_with_the_default_text_draws_no_text_and_embeds_no_font()
    {
        byte[] signed = Sign(new PdfRect(20, 20, 240, 25), new SignatureLook());

        Assert.Equal("", Play(signed).Text.ToString());
        Assert.False(UsesFont(signed));
    }

    [Fact]
    public void A_narrow_field_with_room_for_both_draws_the_picture_and_the_text()
    {
        byte[] signed = Sign(new PdfRect(20, 20, 80, 120), new SignatureLook { Jpeg = Jpeg });

        Assert.True(HasImageObject(signed));
        var seen = Play(signed);
        Assert.Equal(1, seen.Images);
        Assert.NotEqual("", seen.Text.ToString());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void A_picture_is_drawn_on_a_turned_page(int rotate)
    {
        byte[] signed = Sign(new PdfRect(20, 20, 250, 90), new SignatureLook { Jpeg = Jpeg }, rotate: rotate);

        Assert.Equal(1, Play(signed).Images);
        var document = PdfDocument.Open(signed);
        double[] matrix = document.Array(Appearance(document).Dictionary, "Matrix")?.Items.Select(i => ((PdfNumber)i).Value).ToArray() ?? [1, 0, 0, 1, 0, 0];
        double[] expected = rotate switch
        {
            90 => [0, 1, -1, 0, 0, 0],
            180 => [-1, 0, 0, -1, 0, 0],
            270 => [0, -1, 1, 0, 0, 0],
            _ => [1, 0, 0, 1, 0, 0],
        };
        Assert.Equal(expected, matrix);
    }

    [Fact]
    public void A_picture_keeps_the_rectangle_of_an_empty_field()
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 1, new PdfRect(30, 30, 200, 80)));
        var session = PdfEditSession.Open(document.SaveIncremental());

        PdfSigner.Sign(session, SignatureKit.Request(Pki) with { FieldName = "Approval", Look = new SignatureLook { Jpeg = Jpeg } });

        byte[] signed = session.Current.ToArray();
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
        Assert.Equal(new PdfRect(30, 30, 200, 80), PdfForm.Read(PdfDocument.Open(signed)).Find("Approval")!.Widgets[0].Rect);
        Assert.Equal(1, Play(signed, "Approval").Images);
    }

    [Fact]
    public void A_picture_is_signed_into_a_file_with_limited_permissions()
    {
        byte[] id = new byte[16];
        var security = PdfSecurity.Create("", "owner", PdfPermissions.Print | PdfPermissions.Copy, PdfCryptStrength.Aes256, id, new Random(3));
        byte[] limited = PdfDocument.Open(SignatureKit.Plain()).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));

        byte[] signed = Sign(new PdfRect(20, 20, 250, 90), new SignatureLook { Jpeg = Jpeg }, limited);

        Assert.Equal(1, Play(signed).Images);
    }

    [Fact]
    public void A_second_picture_signature_leaves_the_first_one_valid_on_a_form_filling_file()
    {
        byte[] first = PdfSigner.Sign(SignatureChangeTests.FormFile(), SignatureKit.Request(Pki) with { Rect = new PdfRect(10, 10, 120, 40) });

        byte[] second = PdfSigner.Sign(first, Second(new PdfRect(10, 50, 250, 90)));

        var reports = SignatureKit.Verify(second);
        Assert.All(reports, r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        Assert.DoesNotContain(reports[0].Changes.Changes, c => !c.Allowed);
        Assert.True(HasImageObject(second));
    }

    [Fact]
    public void A_picture_signature_after_a_certification_that_allows_filling_changes_nothing_illegal()
    {
        byte[] second = PdfSigner.Sign(SignatureChangeTests.Certified(CertificationLevel.FormFill), Second(new PdfRect(10, 50, 250, 90)));

        var reports = SignatureKit.Verify(second);
        Assert.Equal(2, reports.Count);
        Assert.All(reports, r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        Assert.DoesNotContain(reports[0].Changes.Changes, c => !c.Allowed);
    }

    [Fact]
    public void Filling_a_form_after_a_certification_with_a_picture_changes_nothing_illegal()
    {
        byte[] signed = PdfSigner.Sign(SignatureChangeTests.FormFile(), SignatureKit.Request(Pki) with
        {
            Certify = CertificationLevel.FormFill,
            Rect = new PdfRect(10, 10, 250, 90),
            Look = new SignatureLook { Jpeg = Jpeg },
        });

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Name", "Ada Lovelace"));

        var report = Assert.Single(SignatureKit.Verify(filled));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.DoesNotContain(report.Changes.Changes, c => !c.Allowed);
    }

    [Fact]
    public void A_picture_wider_than_the_box_is_scaled_not_clipped()
    {
        byte[] signed = Sign(new PdfRect(20, 20, 270, 110), new SignatureLook { Image = new PdfRgbaImage(400, 20, new byte[400 * 20 * 4]) });

        var image = Assert.Single(Play(signed).Painted);
        Assert.InRange(image.Bounds.Width, 1, 0.4 * 250 - 6 + 0.001);
        Assert.InRange(image.Bounds.Height, 1, 90 - 6 + 0.001);
    }

    [Theory]
    [InlineData(CertificationLevel.FormFill, SignatureVerdict.ChangedAfterSigning)]
    [InlineData(CertificationLevel.Annotate, SignatureVerdict.Valid)]
    public void Placing_a_stamp_after_a_certification_with_a_picture_gets_the_same_verdict_as_without_one(CertificationLevel level, SignatureVerdict expected)
    {
        byte[] signed = PdfSigner.Sign(SignatureChangeTests.FormFile(), SignatureKit.Request(Pki) with
        {
            Certify = level,
            Rect = new PdfRect(10, 10, 250, 90),
            Look = new SignatureLook { Jpeg = Jpeg },
        });

        byte[] stamped = SignatureChangeTests.Edit(signed, d =>
            new PdfAnnotationWriter(d).AddImageStamp(d.Pages[0], new PdfRect(100, 300, 160, 330), 1, 1, [0, 0, 0, 255]));

        var report = Assert.Single(SignatureKit.Verify(stamped));
        Assert.Equal(expected, report.Verdict);
    }
}
