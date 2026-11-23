using System.Runtime.CompilerServices;
using System.Text;
using System.Windows.Automation.Text;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// The text of one page as UI Automation sees it, and where each character of the page sits in it. Lines are
/// separated by a line feed, blocks by two, cells by a tab, and a line feed ends the page, so an empty page is
/// "\n". Characters without text, soft hyphens and the white space at the ends of a line are left out.
/// </summary>
public sealed class PageUiaText
{
    private static readonly ConditionalWeakTable<TextPage, PageUiaText> Made = [];

    // Per unit of the string: the index of the character it belongs to, or ~(the index of the next character)
    // for a separator and the page break, which belong to no character.
    private readonly int[] _units;
    private readonly int[] _offsets;
    private readonly int[] _words;
    private readonly int[] _lines;
    private readonly int[] _blocks;
    private readonly int[] _formats;

    private PageUiaText(TextPage page)
    {
        var chars = page.Chars;
        var text = new StringBuilder();
        var units = new List<int>();
        var offsets = new int[chars.Count + 1];
        var words = new List<int> { 0 };
        var lines = new List<int> { 0 };
        var blocks = new List<int> { 0 };
        var formats = new List<int> { 0 };
        var dropped = new List<int>();
        var spaces = new List<int>();
        int line = -1, lastBlock = -1;
        bool atStart = true, inWord = false;
        (string Font, double Size, RgbColor Color)? format = null;

        void Flush()
        {
            foreach (int d in dropped) offsets[d] = text.Length;
            dropped.Clear();
        }

        void Add(int index, string value)
        {
            offsets[index] = text.Length;
            text.Append(value);
            for (int k = 0; k < value.Length; k++) units.Add(index);
        }

        void Start(List<int> starts, int offset)
        {
            if (offset > starts[^1]) starts.Add(offset);
        }

        for (int i = 0; i < chars.Count; i++)
        {
            var c = chars[i];
            if (c.Line != line)
            {
                dropped.AddRange(spaces);
                spaces.Clear();
                Flush();
                line = c.Line;
                atStart = true;
                inWord = false;
            }
            if (c.Text.Length == 0 || c.Text == "­")
            {
                dropped.Add(i);
                continue;
            }
            if (c.IsSpace)
            {
                if (atStart) dropped.Add(i);
                else spaces.Add(i);
                continue;
            }
            if (atStart)
            {
                if (text.Length > 0)
                {
                    string separator = page.Lines[line].Before switch
                    {
                        TextBreak.Tab => "\t",
                        TextBreak.Line => "\n",
                        TextBreak.Block => "\n\n",
                        _ => "",
                    };
                    text.Append(separator);
                    for (int k = 0; k < separator.Length; k++) units.Add(~i);
                }
                Flush();
                Start(lines, text.Length);
                int block = page.Lines[line].Block;
                if (block != lastBlock) Start(blocks, text.Length);
                lastBlock = block;
                atStart = false;
            }
            else
            {
                Flush();
            }
            foreach (int s in spaces) Add(s, chars[s].Text);
            if (spaces.Count > 0) inWord = false;
            spaces.Clear();
            if (!inWord) Start(words, text.Length);
            inWord = true;
            var key = (c.Font?.Name ?? "", Math.Round(c.Size, 2), c.Color);
            if (format != key) Start(formats, text.Length);
            format = key;
            Add(i, c.Text);
        }
        dropped.AddRange(spaces);
        Flush();
        text.Append('\n');
        units.Add(~chars.Count);
        offsets[chars.Count] = text.Length;

        Text = text.ToString();
        _units = [.. units];
        _offsets = offsets;
        _words = [.. words];
        _lines = [.. lines];
        _blocks = [.. blocks];
        _formats = [.. formats];
    }

    public static PageUiaText Of(TextPage page) => Made.GetValue(page, p => new PageUiaText(p));

    /// <summary>The page's string, with the page break at its end.</summary>
    public string Text { get; }

    public int Length => Text.Length;

    /// <summary>
    /// The offset of the first unit of a character; a character that has none (no text, a soft hyphen, white space
    /// at the end of a line) is where the next separator or character begins. The character count is the end of the page, past the page break.
    /// </summary>
    public int OffsetOf(int character) => _offsets[Math.Clamp(character, 0, _offsets.Length - 1)];

    /// <summary>The first character a range starting at <paramref name="offset"/> covers: the one that owns that unit, or the next one after a separator.</summary>
    public int CharStart(int offset)
    {
        int v = _units[Math.Clamp(offset, 0, _units.Length - 1)];
        return v >= 0 ? v : ~v;
    }

    /// <summary>The character after the last one a range ending (exclusive) at <paramref name="offset"/> covers; a character cut through is covered whole.</summary>
    public int CharEnd(int offset)
    {
        if (offset <= 0) return 0;
        int v = _units[Math.Min(offset, _units.Length) - 1];
        return v >= 0 ? v + 1 : ~v;
    }

    /// <summary>The offsets where a unit begins, the first being 0; a unit lasts until the next one or the end of the page. Null for a character.</summary>
    public int[]? Starts(TextUnit unit) => unit switch
    {
        TextUnit.Format => _formats,
        TextUnit.Word => _words,
        TextUnit.Line => _lines,
        TextUnit.Paragraph => _blocks,
        TextUnit.Character => null,
        _ => [0],
    };
}
