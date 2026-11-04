using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>A document time stamp is the one signature allowed after a certification that permits no change, and only when it shows nothing and does nothing.</summary>
public class SignatureStampTests
{
    // A time stamp field and its widget added to the empty form of SignatureOverlapTests.FormPdf, the widget written as given.
    private static SignatureChangeReport AddStamp(string widget)
    {
        byte[] before = SignatureOverlapTests.FormPdf().Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before,
            (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Kids [32 0 R] /V 31 0 R>>"),
            (31, SignatureOverlapTests.StampDict),
            (32, widget),
            (33, StreamBody(Evil, Form)));
        return SignatureOverlapTests.Compare(before, after, 1, 31);
    }

    [Fact]
    public void A_widget_with_an_empty_rectangle_and_nothing_else_is_allowed()
    {
        var report = AddStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0 0] /P 3 0 R /AP <</N 33 0 R>>>>");

        Assert.True(report.AllAllowed);
    }

    [Theory]
    [InlineData("[null 0 300 400]")]
    [InlineData("[/a 0 300 400]")]
    [InlineData("[0 0 300 (x)]")]
    [InlineData("[77 0 R 0 300 400]")]
    [InlineData("[0 0 0]")]
    [InlineData("77 0 R")]
    public void A_rectangle_that_is_not_four_numbers_counts_as_an_area(string rect)
    {
        var report = AddStamp($"<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect {rect} /P 3 0 R /AP <</N 33 0 R>>>>");

        Assert.False(report.AllAllowed);
    }

    [Fact]
    public void A_rectangle_written_twice_counts_as_an_area()
    {
        var report = AddStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 300 400] /Rect [0 0 0 0] /P 3 0 R>>");

        Assert.False(report.AllAllowed);
    }

    [Theory]
    [InlineData("/A <</S /JavaScript /JS (x)>>")]
    [InlineData("/AA <</PO <</S /JavaScript /JS (x)>>>>")]
    public void A_widget_with_an_action_is_not_allowed(string action)
    {
        var report = AddStamp($"<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0 0] /P 3 0 R {action}>>");

        Assert.False(report.AllAllowed);
    }
}
