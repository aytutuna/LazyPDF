using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeActionLoopTests
{
    private static byte[] WithOutline(string actions, params (int Number, string Body)[] more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /Outlines /First 7 0 R /Last 7 0 R /Count 1>>");
        pdf.Obj(7, "<</Title (x) /Parent 6 0 R /A 5 0 R>>");
        pdf.Obj(5, actions);
        pdf.Obj(8, "<</S /JavaScript /JS (app.alert) >>");
        foreach (var (number, body) in more) pdf.Obj(number, body);
        return pdf.Finish();
    }

    [Fact]
    public async Task An_action_that_chains_to_itself_is_scanned_and_sanitised()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /GoTo /D [3 0 R /Fit] /Next 5 0 R>>"));
        var sanitizer = new PdfSanitizer(document);

        await Task.Run(() => sanitizer.Scan()).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotNull(sanitizer.Run(new SanitizeOptions()));
    }

    [Theory]
    [InlineData("<</S /GoTo /D [3 0 R /Fit] /Next [8 0 R 8 0 R]>>")]
    [InlineData("<</S /GoTo /D [3 0 R /Fit] /Next [9 0 R 10 0 R]>>")]
    public void A_script_reached_twice_by_the_chain_is_removed_from_every_link(string actions)
    {
        using var document = PdfDocument.Open(WithOutline(actions, (9, "<</S /Named /N /NextPage /Next 8 0 R>>"), (10, "<</S /Named /N /PrevPage /Next 8 0 R>>")));

        var result = new PdfSanitizer(document).Run(new SanitizeOptions());

        Assert.DoesNotContain("app.alert", TestPdf.Text(result.Bytes));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
    }

    [Fact]
    public void A_navigation_node_action_is_filtered()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /PresSteps <</Type /NavNode /NA 5 0 R>>>>");
        pdf.Obj(5, "<</S /JavaScript /JS (app.alert)>>");
        using var document = PdfDocument.Open(pdf.Finish());

        var result = new PdfSanitizer(document).Run(new SanitizeOptions());

        Assert.DoesNotContain("app.alert", TestPdf.Text(result.Bytes));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
    }

    [Fact]
    public void A_script_at_the_end_of_a_long_chain_is_counted_and_follows_the_options()
    {
        var links = Enumerable.Range(0, 70).Select(i => (Number: 20 + i, Body: $"<</S /Named /N /NextPage /Next {21 + i} 0 R>>")).ToList();
        links.Add((90, "<</S /JavaScript /JS (app.alert)>>"));
        using var document = PdfDocument.Open(WithOutline("<</S /GoTo /D [3 0 R /Fit] /Next 20 0 R>>", [.. links]));
        var sanitizer = new PdfSanitizer(document);

        Assert.Equal(1, SanitizeKit.Count(sanitizer.Scan(), SanitizeItem.JavaScript));
        var kept = sanitizer.Run(new SanitizeOptions { JavaScript = false });
        Assert.Contains("app.alert", TestPdf.Text(kept.Bytes));
        Assert.Equal(1, SanitizeKit.Count(kept.Kept, SanitizeItem.JavaScript));
        Assert.DoesNotContain("app.alert", TestPdf.Text(sanitizer.Run(new SanitizeOptions()).Bytes));
    }

    [Fact]
    public void An_action_of_an_unknown_type_does_not_hide_the_script_chained_after_it()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /GoToDp /Next 8 0 R>>"));

        var result = new PdfSanitizer(document).Run(new SanitizeOptions());

        Assert.DoesNotContain("app.alert", TestPdf.Text(result.Bytes));
    }

    [Fact]
    public async Task A_field_that_is_its_own_parent_is_scanned_and_sanitised()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(5, "<</FT /Tx /T (a) /V (x) /Parent 5 0 R>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var sanitizer = new PdfSanitizer(document);

        await Task.Run(() => sanitizer.Scan()).WaitAsync(TimeSpan.FromSeconds(10));
        await Task.Run(() => sanitizer.Run(new SanitizeOptions())).WaitAsync(TimeSpan.FromSeconds(10));
    }

    [Fact]
    public void An_action_chained_after_a_removed_one_is_still_counted()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /URI /URI (http://x.example) /Next 8 0 R>>"));

        var found = new PdfSanitizer(document).Scan();

        Assert.Equal(1, SanitizeKit.Count(found, SanitizeItem.JavaScript));
        Assert.Equal(1, SanitizeKit.Count(found, SanitizeItem.ExternalLinks));
    }

    [Fact]
    public void An_action_chained_after_a_removed_one_stays_when_its_kind_is_kept()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /URI /URI (http://x.example) /Next 8 0 R>>"));

        var result = new PdfSanitizer(document).Run(new SanitizeOptions { JavaScript = false });

        Assert.Contains("app.alert", TestPdf.Text(result.Bytes));
        Assert.DoesNotContain("x.example", TestPdf.Text(result.Bytes));
        Assert.Equal(1, SanitizeKit.Count(result.Kept, SanitizeItem.JavaScript));
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.ExternalLinks));
    }

    [Fact]
    public void Actions_kept_behind_a_removed_one_all_stay()
    {
        using var document = PdfDocument.Open(WithOutline("<</S /URI /URI (http://x.example) /Next [8 0 R 9 0 R]>>", (9, "<</S /JavaScript /JS (second.script)>>")));

        var result = new PdfSanitizer(document).Run(new SanitizeOptions { JavaScript = false });

        Assert.Contains("app.alert", TestPdf.Text(result.Bytes));
        Assert.Contains("second.script", TestPdf.Text(result.Bytes));
        Assert.Equal(2, SanitizeKit.Count(result.Kept, SanitizeItem.JavaScript));
    }
}
