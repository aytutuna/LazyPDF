using System.Globalization;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Combine;

public enum SplitBy { Count, Size, Bookmarks }

/// <summary>The parts of Combine that do not need a window: how a file is cut, and what the parts are called.</summary>
internal static class CombineJob
{
    public const long MegabyteBytes = 1024 * 1024;

    /// <summary>Pages per part, or megabytes per part, as typed; false when it is not a number that makes sense for <paramref name="by"/>.</summary>
    public static bool TryAmount(SplitBy by, string text, out double amount)
    {
        amount = 0;
        if (by == SplitBy.Bookmarks) return true;
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out amount)) return false;
        return by == SplitBy.Count ? amount >= 1 && amount == Math.Floor(amount) && amount <= int.MaxValue : amount >= 0.01 && amount <= 100_000;
    }

    public static IReadOnlyList<PdfDocument> Split(PdfDocument source, SplitBy by, double amount) => by switch
    {
        SplitBy.Count => PageAssembly.SplitEvery(source, (int)amount),
        SplitBy.Size => PageAssembly.SplitBySize(source, (long)(amount * MegabyteBytes)),
        _ => PageAssembly.SplitAt(source, BookmarkStarts(source)),
    };

    /// <summary>The pages the top-level bookmarks point at, in the order of the outline.</summary>
    public static IReadOnlyList<int> BookmarkStarts(PdfDocument document) =>
        [.. Outline.Read(document).Items
            .Select(item => item.Destination?.PageIndex ?? (item.Action as GoToAction)?.Destination.PageIndex ?? -1)
            .Where(page => page >= 0 && page < document.Pages.Count)];

    /// <summary>How many parts a split at the bookmarks makes: bookmarks on the same page, or on the first, add none.</summary>
    public static int BookmarkParts(PdfDocument document) => BookmarkStarts(document).Where(page => page != 0).Distinct().Count() + 1;

    public static string PartName(string stem, int part, int parts) =>
        $"{stem} {(part + 1).ToString("D" + Math.Max(parts.ToString(CultureInfo.InvariantCulture).Length, 1), CultureInfo.InvariantCulture)}.pdf";

    /// <summary><paramref name="name"/> in <paramref name="folder"/>, or with " (2)", " (3)" and so on when the folder has it already.</summary>
    public static string UniquePath(string folder, string name)
    {
        string path = Path.Combine(folder, name);
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{stem} ({n}){extension}");
        return path;
    }
}
