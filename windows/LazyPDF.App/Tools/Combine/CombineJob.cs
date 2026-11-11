using System.Globalization;
using System.Text.RegularExpressions;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Combine;

public enum SplitBy { Count, Size, Bookmarks, EachPage, Ranges }

/// <summary>The parts of Combine that do not need a window: how a file is cut, and what the parts are called.</summary>
internal static class CombineJob
{
    public const long MegabyteBytes = 1024 * 1024;

    private static readonly Regex Reserved = new(@"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOptions.IgnoreCase);

    /// <summary>Pages per part, or megabytes per part, as typed; false when it is not a number that makes sense for <paramref name="by"/>. Ranges are checked against <paramref name="pageCount"/>.</summary>
    public static bool TryAmount(SplitBy by, string text, out double amount, int pageCount = 0)
    {
        amount = 0;
        if (by is SplitBy.Bookmarks or SplitBy.EachPage) return true;
        if (by == SplitBy.Ranges) return ParseRanges(text, pageCount).Error is null;
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out amount)) return false;
        return by == SplitBy.Count ? amount >= 1 && amount == Math.Floor(amount) && amount <= int.MaxValue : amount >= 0.01 && amount <= 100_000;
    }

    public static IReadOnlyList<PdfDocument> Split(PdfDocument source, SplitBy by, double amount, CancellationToken cancel = default, IReadOnlyList<IReadOnlyList<int>>? ranges = null) => by switch
    {
        SplitBy.Count => PageAssembly.SplitEvery(source, (int)amount, cancel),
        SplitBy.Size => PageAssembly.SplitBySize(source, (long)(amount * MegabyteBytes), cancel: cancel),
        SplitBy.EachPage => PageAssembly.SplitEvery(source, 1, cancel),
        SplitBy.Ranges => PageAssembly.SplitByRanges(source, ranges ?? [], cancel),
        _ => PageAssembly.SplitAt(source, BookmarkStarts(source), cancel),
    };

    /// <summary>The pages of each range typed between semicolons, or the message for the first one that cannot be read.</summary>
    public static (IReadOnlyList<IReadOnlyList<int>> Ranges, string? Error) ParseRanges(string text, int pageCount)
    {
        var ranges = new List<IReadOnlyList<int>>();
        foreach (string segment in text.Split(';').Select(s => s.Trim()).Where(s => s.Length > 0))
        {
            var range = PageRange.Parse(segment, pageCount);
            if (range.Error is { } error) return ([], Loc.T("{0}: {1}", segment, error.Message));
            ranges.Add(range.Pages);
        }
        return ranges.Count == 0 ? ([], Loc.T("Type at least one range.")) : (ranges, null);
    }

    /// <summary>The pages the top-level bookmarks point at, in the order of the outline.</summary>
    public static IReadOnlyList<int> BookmarkStarts(PdfDocument document) =>
        [.. Outline.Read(document).Items.Select(PageOf).Where(page => page >= 0 && page < document.Pages.Count)];

    private static int PageOf(OutlineItem item) => item.Destination?.PageIndex ?? (item.Action as GoToAction)?.Destination.PageIndex ?? -1;

    /// <summary>The title of the first top-level bookmark on the first page of each part of a split at the bookmarks, in the order of the parts; null where a part has none.</summary>
    public static IReadOnlyList<string?> BookmarkTitles(PdfDocument document)
    {
        var items = Outline.Read(document).Items;
        string? TitleAt(int page) => items.FirstOrDefault(item => PageOf(item) == page)?.Title;
        return [TitleAt(0), .. BookmarkStarts(document).Where(page => page != 0).Distinct().Order().Select(TitleAt)];
    }

    /// <summary>How many of the parts are bigger than <paramref name="limit"/> bytes.</summary>
    public static int PartsOver(IEnumerable<byte[]> parts, long limit) => parts.Count(part => part.Length > limit);

    /// <summary>How many parts a split by pages or at each page makes, before it runs; null for the kinds that need more than the page count.</summary>
    public static int? EstimatedParts(SplitBy by, int pages, double amount) => by switch
    {
        SplitBy.Count => (int)Math.Ceiling(pages / amount),
        SplitBy.EachPage => pages,
        _ => null,
    };

    /// <summary>How many parts a split at the bookmarks makes: bookmarks on the same page, or on the first, add none.</summary>
    public static int BookmarkParts(PdfDocument document) => BookmarkStarts(document).Where(page => page != 0).Distinct().Count() + 1;

    public static string Oversize(IReadOnlyList<byte[]> parts, double megabytes)
    {
        int over = PartsOver(parts, (long)(megabytes * MegabyteBytes));
        return over == 0 ? "" : Loc.Plural(over, "{0} part is bigger than {1} MB. A single page is too large to fit.", "{0} parts are bigger than {1} MB. A single page is too large to fit.", megabytes);
    }

    public static string FolderNote(string folder, bool protectedSource, string extra)
    {
        var sentences = new List<string>();
        if (protectedSource) sentences.Add(CopyRules.Unprotected);
        if (extra.Length > 0) sentences.Add(extra);
        return sentences.Count == 0 ? folder : folder + ". " + string.Join(" ", sentences);
    }

    /// <summary>The name without ".pdf", or "File n" when nothing is left of it.</summary>
    public static string BookmarkTitle(string name, int n)
    {
        string title = name.Trim();
        if (title.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) title = title[..^4].Trim();
        return title.Length == 0 ? Loc.T("File {0}", n) : title;
    }

    /// <summary>One bookmark per source at its first page in <paramref name="merged"/>; <paramref name="sources"/> holds each one's name and the pages it gave.</summary>
    public static void AddFileBookmarks(PdfDocument merged, IReadOnlyList<(string Name, int Pages)> sources)
    {
        var outline = Outline.Read(merged);
        int start = 0;
        for (int i = 0; i < sources.Count; i++)
        {
            outline.Add(new OutlineItem { Title = BookmarkTitle(sources[i].Name, i + 1), Destination = new PdfDestination(start) });
            start += sources[i].Pages;
        }
        outline.Write(merged);
    }

    public static string PartName(string stem, int part, int parts) => PartName(stem, part, parts, null);

    /// <summary>Named after <paramref name="title"/> when it makes a usable file name, else numbered.</summary>
    public static string PartName(string stem, int part, int parts, string? title)
    {
        if (title is not null)
        {
            string clean = string.Join("_", title.Split(Path.GetInvalidFileNameChars()));
            while (clean.Contains("  ")) clean = clean.Replace("  ", " ");
            // 255 is the NTFS name limit; 4 is left for " (n)" and the rest for " - " and ".pdf".
            int room = Math.Min(80, 255 - stem.Length - 3 - 4 - 4);
            clean = room <= 0 ? "" : clean.Length > room ? clean[..room] : clean;
            clean = clean.Trim('.', ' ');
            if (clean.Length > 0 && !Reserved.IsMatch(clean)) return $"{stem} - {clean}.pdf";
        }
        return $"{stem} {(part + 1).ToString("D" + Math.Max(parts.ToString(CultureInfo.InvariantCulture).Length, 1), CultureInfo.InvariantCulture)}.pdf";
    }

    /// <summary><paramref name="name"/> in <paramref name="folder"/>, or with " (2)", " (3)" and so on when the folder has it already.</summary>
    public static string UniquePath(string folder, string name)
    {
        string path = Path.Combine(folder, name);
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{stem} ({n}){extension}");
        return path;
    }
}
