using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureRegeneratedTests
{
    private static readonly Pki Pki = Pki.Instance;

    // The annotation is written again under generation 1 and the page lists that one, so no reference to generation 0 is left.
    private static byte[] Regenerate(byte[] signed, bool keepOldReference)
    {
        var document = PdfDocument.Open(signed);
        var page = document.Pages[0];
        int stamp = PdfAnnotations.Read(document, page).First(a => a.Type == AnnotationType.Stamp).Reference!.Number;
        int holder = page.Reference!.Number;
        var annots = page.Dictionary["Annots"];
        if (annots is PdfReference listed) holder = listed.Number;

        string moved = Regex.Replace(document.Get(holder)!.ToString()!, $@"\b{stamp} 0 R", keepOldReference ? $"{stamp} 0 R {stamp} 1 R" : $"{stamp} 1 R");
        var text = new StringBuilder("\n");
        long stampAt = signed.Length + text.Length;
        text.Append($"{stamp} 1 obj\n{document.Get(stamp)}\nendobj\n");
        long holderAt = signed.Length + text.Length;
        text.Append($"{holder} 0 obj\n{moved}\nendobj\n");
        long xref = signed.Length + text.Length;
        text.Append("xref\n");
        foreach (var (number, generation, at) in new[] { (stamp, 1, stampAt), (holder, 0, holderAt) }.OrderBy(e => e.Item1))
            text.Append($"{number} 1\n{at:D10} {generation:D5} n \n");
        text.Append($"trailer\n<</Size {document.NextObjectNumber}{SignatureRawKit.Kept(document)} /Prev {document.StartXref}>>\nstartxref\n{xref}\n%%EOF\n");
        return [.. signed, .. TestPdf.Latin(text.ToString())];
    }

    private static byte[] Signed() => PdfSigner.Sign(
        SignatureChangeTests.Edit(SignatureChangeTests.FormFile(), d => new PdfAnnotationWriter(d).AddStamp(d.Pages[0], new PdfRect(30, 280, 270, 330), "VOID")),
        SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });

    [Fact]
    public void AnAnnotationMovedToANewGenerationIsNotAllowedWhateverIsLeftOfTheOldReference()
    {
        var report = SignatureKit.Verify(Regenerate(Signed(), keepOldReference: false))[0];

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Other);
    }

    [Fact]
    public void AnAnnotationStillListedWithItsOldGenerationIsNotAllowed()
    {
        var report = SignatureKit.Verify(Regenerate(Signed(), keepOldReference: true))[0];

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Other);
    }

    [Fact]
    public void A_page_whose_holder_already_names_the_new_generation_is_compared_with_the_signed_page()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 5 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>");
        pdf.Stream(4, "", "BT ET");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        var document = PdfDocument.Open(signed);
        string page = document.Get(3)!.ToString()!.Replace("/Contents 4 0 R", "/Contents 30 0 R");
        var text = new StringBuilder("\n");
        long pageAt = signed.Length + text.Length;
        text.Append($"3 5 obj\n{page}\nendobj\n");
        long contentAt = signed.Length + text.Length;
        text.Append($"30 0 obj\n{SignatureRawKit.StreamBody(SignatureRawKit.Evil)}\nendobj\n");
        long table = signed.Length + text.Length;
        text.Append($"xref\n3 1\n{pageAt:D10} 00005 n \n30 1\n{contentAt:D10} 00000 n \ntrailer\n<</Size 31{SignatureRawKit.Kept(document)} /Prev {document.StartXref}>>\nstartxref\n{table}\n%%EOF\n");
        byte[] attacked = [.. signed, .. TestPdf.Latin(text.ToString())];

        Assert.True(SignatureRawKit.ShowsEvil(attacked));
        var report = SignatureKit.Verify(attacked)[0];
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.PageContent);
    }
}
