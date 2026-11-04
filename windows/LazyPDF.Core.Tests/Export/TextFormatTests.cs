using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TextFormatTests
{
    private static readonly ExportDocument Report = ExportLayout.Analyze(ExportKit.Report());

    private static ExportDocument Turkish(string text) =>
        new("Başlık", [new ExportPage(0, 612, 792, [new ExportParagraph(new DisplayRect(72, 72, 400, 14), [new ExportRun(text, false, false, 11)])], [], [])], 11);

    [Fact]
    public void ReflowedHtmlIsSemanticAndSelfContained()
    {
        string html = HtmlWriter.Reflowed(Report);
        Assert.StartsWith("<!DOCTYPE html>", html);
        Assert.Contains("<h1>Annual Report</h1>", html);
        Assert.Contains("<p>First line of the opening paragraph that runs on to a second line and stops there.</p>", html);
        Assert.Contains("<strong>important</strong>", html);
        Assert.Contains("<em>words.</em>", html);
        Assert.Contains("<ul>\n<li>Apples</li>\n<li>Pears</li>\n</ul>", html);
        Assert.Contains("<ol>\n<li>First step</li>\n<li>Second step</li>\n</ol>", html);
        Assert.Contains("<td>Tea</td><td>1,250.50</td>", html);
        Assert.Contains("<img src=\"data:image/jpeg;base64,/9j/", html);
        Assert.DoesNotContain("Confidential", html);
        Assert.Equal(3, Count(html, "<section "));
        Assert.DoesNotContain("src=\"http", html);
        Assert.DoesNotContain("<link", html);
        foreach (string tag in new[] { "ul", "ol", "table", "section", "li", "tr" }) Assert.Equal(Count(html, $"<{tag}>") + Count(html, $"<{tag} "), Count(html, $"</{tag}>"));
    }

    [Fact]
    public void NestedListsNestInHtml()
    {
        var blocks = new ExportBlock[]
        {
            Item("a", 0), Item("b", 1), Item("c", 1), Item("d", 0),
        };
        string html = HtmlWriter.Reflowed(new ExportDocument(null, [new ExportPage(0, 612, 792, blocks, [], [])], 11));
        Assert.Contains("<ul>\n<li>a<ul>\n<li>b</li>\n<li>c</li>\n</ul>\n</li>\n<li>d</li>\n</ul>", html);
    }

    [Fact]
    public void HtmlEscapesAndKeepsTurkishLetters()
    {
        string html = HtmlWriter.Reflowed(Turkish("Çağrı <b> & \"ğüşıİ\""));
        Assert.Contains("<title>Başlık</title>", html);
        Assert.Contains("Çağrı &lt;b&gt; &amp; &quot;ğüşıİ&quot;", html);
    }

    [Fact]
    public void FixedHtmlPlacesEveryLineAndHasNoPictures()
    {
        string html = HtmlWriter.Fixed(Report);
        Assert.Contains("class=\"page\"", html);
        Assert.Contains("style=\"width:612pt;height:792pt\"", html);
        Assert.Contains("left:72pt;top:", html);
        Assert.Contains("Confidential", html);
        Assert.DoesNotContain("<img", html);
        Assert.Equal(Report.Pages.Sum(p => p.Lines.Count), Count(html, "<span style=\"left:"));
        Assert.Contains("font-weight:bold", html);
        Assert.Contains("font-style:italic", html);
    }

    [Fact]
    public void RtfEscapesTurkishAsUnicodeAndKeepsTheStructure()
    {
        string rtf = RtfWriter.Make(Turkish("ğ Ş ı İ {x} \\"));
        Assert.StartsWith(@"{\rtf1\ansi", rtf);
        Assert.Contains(@"\u287? \u350? \u305? \u304? \{x\} \\", rtf);
        Assert.Contains(@"{\title Ba\u351?l\u305?k}", rtf);
        Assert.True(Balanced(rtf));

        string report = RtfWriter.Make(Report);
        Assert.True(Balanced(report));
        Assert.Contains(@"\trowd", report);
        Assert.Contains(@"\pict\jpegblip", report);
        Assert.Contains(Convert.ToHexStringLower(ExportKit.Jpeg), report);
        Assert.Contains(@"\u8226?\tab ", report);
        Assert.Contains(@"1.\tab ", report);
        Assert.Equal(2, Count(report, @"\page"));
        Assert.DoesNotContain("Confidential", report);
    }

    [Fact]
    public void MarkdownHasHeadingsEmphasisListsAndTables()
    {
        string md = MarkdownWriter.Make(Report);
        Assert.StartsWith("# Annual Report\n\nFirst line", md);
        Assert.Contains("Second paragraph with **important** *words.*", md);
        Assert.Contains("- Apples\n- Pears\n\n1. First step\n2. Second step\n\n", md);
        Assert.Contains("| Item | Price |\n| --- | --- |\n| Tea | 1,250.50 |", md);
        Assert.Equal(2, Count(md, "\n---\n"));
        Assert.DoesNotContain("data:", md);
        Assert.Contains("(data:image/jpeg;base64,", MarkdownWriter.Make(Report, embedImages: true));
        Assert.EndsWith("\n", md);
    }

    [Fact]
    public void MarkdownEscapesWhatWouldBeSyntax()
    {
        string md = MarkdownWriter.Make(Turkish("# not a heading *star* _under_ [link] a|b"));
        Assert.Contains(@"\# not a heading \*star\* \_under\_ \[link\] a\|b", md);
        Assert.Contains("1\\. not a list", MarkdownWriter.Make(Turkish("1. not a list")));
        Assert.Contains("ğüşıİ", MarkdownWriter.Make(Turkish("ğüşıİ")));
    }

    [Fact]
    public void PlainTextKeepsParagraphsListsAndTabbedCells()
    {
        string text = PlainTextWriter.Make(Report);
        Assert.StartsWith("Annual Report\n\nFirst line of the opening paragraph that runs on to a second line and stops there.\n\nSecond paragraph with important words.\n\n- Apples\n- Pears\n\n1. First step\n2. Second step\n\n", text);
        Assert.Contains("Item\tPrice\nTea\t1,250.50\n", text);
        Assert.Equal(3, text.Count(c => c == '\f'));
        Assert.DoesNotContain("Confidential", text);
    }

    [Fact]
    public void EmptyDocumentsGiveEmptyOrMinimalText()
    {
        var empty = new ExportDocument(null, [], 11);
        Assert.Equal("", PlainTextWriter.Make(empty));
        Assert.Equal("", MarkdownWriter.Make(empty));
        Assert.True(Balanced(RtfWriter.Make(empty)));
        Assert.Contains("<body>", HtmlWriter.Reflowed(empty));
        Assert.Contains("<body>", HtmlWriter.Fixed(empty));
    }

    private static ExportParagraph Item(string text, int level) =>
        new(new DisplayRect(72 + 18 * level, 72, 100, 12), [new ExportRun(text, false, false, 11)], 0, new ExportListItem(1, false, level, 0));

    private static int Count(string text, string part)
    {
        int n = 0;
        for (int at = text.IndexOf(part, StringComparison.Ordinal); at >= 0; at = text.IndexOf(part, at + part.Length, StringComparison.Ordinal)) n++;
        return n;
    }

    private static bool Balanced(string rtf)
    {
        int depth = 0;
        for (int i = 0; i < rtf.Length; i++)
        {
            if (rtf[i] == '\\') i++;
            else if (rtf[i] == '{') depth++;
            else if (rtf[i] == '}' && --depth < 0) return false;
        }
        return depth == 0;
    }
}
