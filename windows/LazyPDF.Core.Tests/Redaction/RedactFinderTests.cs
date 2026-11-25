using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactFinderTests
{
    private static PdfDocument Lines(params string[] lines) =>
        RedactionKit.Page(string.Join(" ", lines.Select((l, i) => $"BT /F1 11 Tf 50 {750 - 30 * i} Td ({l}) Tj ET")));

    private static List<string> Found(PdfDocument document, RedactionKind kind) =>
        [.. RedactionFinder.Find(document, kind).Select(m => m.Text)];

    [Fact]
    public void Emails()
    {
        using var document = Lines("Write to jane.doe+tag@example.co.uk now", "not an address: @example.com or jane@", "bob@x.org.");
        Assert.Equal(["jane.doe+tag@example.co.uk", "bob@x.org"], Found(document, RedactionKind.Email));
    }

    [Fact]
    public void Phones()
    {
        using var document = Lines("Call +90 532 123 45 67 today", "Office (212) 555-0147", "Not one: 2024-03-15 or 1234", "Plain 0532 123 4567");
        var found = Found(document, RedactionKind.Phone);
        Assert.Contains("+90 532 123 45 67", found);
        Assert.Contains("(212) 555-0147", found);
        Assert.Contains("0532 123 4567", found);
        Assert.DoesNotContain(found, f => f.Contains("2024"));
        Assert.Equal(3, found.Count);
    }

    [Fact]
    public void UsSocialSecurityNumbersKeepTheirRules()
    {
        using var document = Lines("SSN 123-45-6789 ok", "Bad 000-12-3456 and 666-12-3456 and 123-00-6789 and 123-45-0000 and 912-34-5678");
        Assert.Equal(["123-45-6789"], Found(document, RedactionKind.UsSocialSecurity));
    }

    [Fact]
    public void TurkishIdNumbersNeedTheirChecksum()
    {
        using var document = Lines("T.C. 10000000146 geçerli", "Hatalı 10000000147 ve 01234567890 ve 123456789012");
        var found = RedactionFinder.Find(document, RedactionKind.TurkishId);
        Assert.Equal("10000000146", Assert.Single(found).Text);
    }

    [Fact]
    public void IbansAreCheckedModNinetySevenAndCutWhereTheNumberEnds()
    {
        using var document = Lines("IBAN TR33 0006 1005 1978 6457 8413 26 hesap", "DE89 3704 0044 0532 0130 00 and DE89 3704 0044 0532 0130 01", "ES91 2100 0418 4502 0005 1332 BANK");
        var found = Found(document, RedactionKind.Iban);
        Assert.Equal(["TR33 0006 1005 1978 6457 8413 26", "DE89 3704 0044 0532 0130 00", "ES91 2100 0418 4502 0005 1332"], found);
    }

    [Fact]
    public void PaymentCardsNeedLuhn()
    {
        using var document = Lines("Card 4111 1111 1111 1111 exp", "Wrong 4111 1111 1111 1112", "Dashes 5500-0000-0000-0004 done");
        Assert.Equal(["4111 1111 1111 1111", "5500-0000-0000-0004"], Found(document, RedactionKind.PaymentCard));
    }

    [Fact]
    public void Dates()
    {
        using var document = Lines("On 2024-03-15 and 15.03.2024 and 03/15/2024", "March 5, 2024 and 5 Mart 2024 and 17 Haziran 1999", "Not 2024-13-45 or 99.99.2024");
        var found = Found(document, RedactionKind.Date);
        Assert.Equal(["2024-03-15", "15.03.2024", "03/15/2024", "March 5, 2024", "5 Mart 2024"], found.Take(5));
        Assert.Equal(6, found.Count);
        Assert.DoesNotContain("2024-13-45", found);
    }

    [Fact]
    public void RegularExpressionAndWordList()
    {
        using var document = Lines("Invoice INV-00123 for Acme and ACME corp", "Another INV-99999 plus acmeware");
        var cache = new TextCache(document);
        Assert.Equal(["INV-00123", "INV-99999"], RedactionFinder.FindRegex(cache, @"INV-\d{5}").Select(m => m.Text));
        Assert.Equal(["Acme", "ACME"], RedactionFinder.FindWords(cache, ["acme"]).Select(m => m.Text));
        Assert.Equal(3, RedactionFinder.FindWords(cache, ["acme"], wholeWord: false).Count);
        Assert.Single(RedactionFinder.FindWords(cache, ["Acme"], matchCase: true));
        Assert.ThrowsAny<ArgumentException>(() => RedactionFinder.FindRegex(cache, "(unclosed"));
    }

    [Fact]
    public void APatternThatRunsOutOfTimeIsReportedByPage()
    {
        using var document = Lines(new string('a', 40) + "!");
        var cache = new TextCache(document);
        var timeouts = new SearchTimeouts();
        Assert.Empty(RedactionFinder.FindRegex(cache, "^(a+)+$", timeouts: timeouts));
        Assert.Equal([0], timeouts.Pages);
        var quiet = new SearchTimeouts();
        Assert.Single(RedactionFinder.FindRegex(cache, "a+!", timeouts: quiet));
        Assert.Empty(quiet.Pages);
    }

    [Fact]
    public void MatchesBecomeMarksThatRemoveTheText()
    {
        using var document = Lines("Mail jane@example.com please", "and bob@example.org too");
        var found = RedactionFinder.Find(document, RedactionKind.Email);
        var result = new PdfRedactor(document).Apply(found.Select(m => m.Mark).ToList());
        using var output = RedactionKit.Open(result);
        Assert.Equal("Mail  pleaseand  too", RedactionKit.Text(output));
        Assert.False(RedactionKit.Holds(result.Bytes, "example"));
    }

    [Fact]
    public void ABadKindIsRefused()
    {
        using var document = Lines("x");
        Assert.Throws<ArgumentOutOfRangeException>(() => RedactionFinder.Find(document, RedactionKind.Word));
    }
}
