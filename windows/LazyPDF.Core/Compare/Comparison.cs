namespace LazyPDF.Core;

internal sealed partial class Comparison
{
    private const int MinMoveWords = 4;
    private const int MaxSlide = 64;
    private const int PoorText = 10;

    private readonly PdfDocument _before;
    private readonly PdfDocument _after;
    private readonly CompareOptions _options;
    private readonly CancellationToken _cancellation;
    private readonly PageReader _oldReader;
    private readonly PageReader _newReader;

    public Comparison(PdfDocument before, PdfDocument after, CompareOptions options, CancellationToken cancellation)
    {
        _before = before;
        _after = after;
        _options = options;
        _cancellation = cancellation;
        var ids = new Dictionary<string, int>();
        _oldReader = new PageReader(before, options, ids, cancellation);
        _newReader = new PageReader(after, options, ids, cancellation);
    }

    private sealed class TextHunk(int pair, SequenceDiff.Hunk range, PageData oldData, PageData newData)
    {
        public int Pair { get; } = pair;
        public SequenceDiff.Hunk Range { get; } = range;
        public string OldText { get; } = oldData.Words(range.OldStart, range.OldCount);
        public string NewText { get; } = newData.Words(range.NewStart, range.NewCount);
        public List<TextQuad> OldQuads { get; } = range.OldCount > 0 ? oldData.Quads(range.OldStart, range.OldCount) : oldData.Anchor(range.OldStart);
        public List<TextQuad> NewQuads { get; } = range.NewCount > 0 ? newData.Quads(range.NewStart, range.NewCount) : newData.Anchor(range.NewStart);
        public string Key { get; } = string.Join(',', range.OldCount == 0 ? newData.Ids.AsSpan(range.NewStart, range.NewCount).ToArray() : oldData.Ids.AsSpan(range.OldStart, range.OldCount).ToArray());
        public TextHunk? Partner { get; set; }
    }

    private sealed class PairWork(PagePair pair)
    {
        public PagePair Pair { get; } = pair;
        public List<TextHunk> Hunks { get; } = [];
        public List<CompareChange> Others { get; } = [];
    }

    public ComparisonResult Run()
    {
        var (oldSignatures, oldPoor) = Signatures(_oldReader);
        var (newSignatures, newPoor) = Signatures(_newReader);
        var pairs = PageAligner.Align(oldSignatures, newSignatures, oldPoor, newPoor, _cancellation);
        var work = new List<PairWork>();
        for (int p = 0; p < pairs.Count; p++)
        {
            _cancellation.ThrowIfCancellationRequested();
            var item = new PairWork(pairs[p]);
            ComparePair(p, item);
            work.Add(item);
        }
        FindMoves(work);

        var changes = new List<CompareChange>();
        int wordsAdded = 0, wordsRemoved = 0;
        foreach (var item in work)
        {
            foreach (var change in item.Others.Where(c => c.Area == ChangeArea.Page)) changes.Add(change);
            foreach (var hunk in item.Hunks)
            {
                if (hunk.Partner is not null && hunk.Range.NewCount == 0) continue;
                var pair = item.Pair;
                if (hunk.Partner is { } source)
                {
                    changes.Add(new CompareChange(ChangeKind.Moved, ChangeArea.Text, work[source.Pair].Pair.OldIndex, pair.NewIndex,
                        source.OldText, hunk.NewText, source.OldQuads, hunk.NewQuads, CompareText.MovedFrom(work[source.Pair].Pair.OldIndex)));
                    continue;
                }
                var kind = hunk.Range.OldCount == 0 ? ChangeKind.Added : hunk.Range.NewCount == 0 ? ChangeKind.Removed : ChangeKind.Changed;
                wordsAdded += hunk.Range.NewCount;
                wordsRemoved += hunk.Range.OldCount;
                changes.Add(new CompareChange(kind, ChangeArea.Text, pair.OldIndex, pair.NewIndex, hunk.OldText, hunk.NewText, hunk.OldQuads, hunk.NewQuads));
            }
            foreach (var change in item.Others.Where(c => c.Area != ChangeArea.Page)) changes.Add(change);
        }
        CompareDocuments(pairs, changes);
        return new ComparisonResult(pairs, changes, Summarize(changes, wordsAdded, wordsRemoved), _before.Pages.Count, _after.Pages.Count);
    }

    private static ComparisonSummary Summarize(List<CompareChange> changes, int wordsAdded, int wordsRemoved)
    {
        int Kind(ChangeKind k) => changes.Count(c => c.Kind == k);
        int Area(ChangeArea a) => changes.Count(c => c.Area == a);
        return new ComparisonSummary(Kind(ChangeKind.Added), Kind(ChangeKind.Removed), Kind(ChangeKind.Changed), Kind(ChangeKind.Moved),
            Area(ChangeArea.Text), Area(ChangeArea.Format), Area(ChangeArea.Image), Area(ChangeArea.Annotation), Area(ChangeArea.Page), Area(ChangeArea.Document),
            wordsAdded, wordsRemoved);
    }

    /// <summary>The shingles of each page; a page with little text also counts its pictures, so that scans and slides can be paired.</summary>
    private (List<int[]> Signatures, List<bool> TextPoor) Signatures(PageReader reader)
    {
        var result = new List<int[]>();
        var poor = new List<bool>();
        for (int i = 0; i < reader.Count; i++)
        {
            _cancellation.ThrowIfCancellationRequested();
            var data = reader.Load(i);
            var shingles = new HashSet<int>();
            if (data.Ids.Length == 1) shingles.Add(data.Ids[0]);
            for (int k = 0; k + 1 < data.Ids.Length; k++) shingles.Add(HashCode.Combine(data.Ids[k], data.Ids[k + 1]));
            poor.Add(data.Ids.Length < PoorText);
            if (data.Ids.Length < PoorText)
            {
                foreach (var image in reader.Images(data.Page)) shingles.Add(StringComparer.Ordinal.GetHashCode(image.Hash));
            }
            var sorted = shingles.ToArray();
            Array.Sort(sorted);
            result.Add(sorted);
        }
        return (result, poor);
    }

    private void ComparePair(int index, PairWork work)
    {
        var pair = work.Pair;
        if (pair.IsAdded || pair.IsRemoved)
        {
            var page = pair.IsAdded ? _after.Pages[pair.NewIndex] : _before.Pages[pair.OldIndex];
            var box = new[] { BoxQuad(page.CropBox) };
            work.Others.Add(new CompareChange(pair.IsAdded ? ChangeKind.Added : ChangeKind.Removed, ChangeArea.Page, pair.OldIndex, pair.NewIndex, "", "",
                pair.IsAdded ? [] : box, pair.IsAdded ? box : [], pair.IsAdded ? CompareText.PageAdded : CompareText.PageRemoved));
            return;
        }

        var oldData = _oldReader.Load(pair.OldIndex);
        var newData = _newReader.Load(pair.NewIndex);
        if (pair.Moved)
        {
            work.Others.Add(new CompareChange(ChangeKind.Moved, ChangeArea.Page, pair.OldIndex, pair.NewIndex, "", "",
                [BoxQuad(oldData.Page.CropBox)], [BoxQuad(newData.Page.CropBox)], CompareText.PageMoved));
        }
        CompareSize(work, oldData.Page, newData.Page);

        var hunks = SequenceDiff.Diff(oldData.Ids, newData.Ids);
        for (int k = 0; k < hunks.Count; k++) hunks[k] = Slide(hunks[k], k > 0 ? hunks[k - 1] : null, k + 1 < hunks.Count ? hunks[k + 1] : null, oldData, newData);
        foreach (var hunk in hunks)
        {
            if (_options.IgnoreWhiteSpace && hunk.OldCount > 0 && hunk.NewCount > 0 && Squash(oldData, hunk.OldStart, hunk.OldCount) == Squash(newData, hunk.NewStart, hunk.NewCount)) continue;
            work.Hunks.Add(new TextHunk(index, hunk, oldData, newData));
        }
        CompareFormats(work, oldData, newData, hunks);
        CompareImages(work, oldData.Page, newData.Page);
        CompareAnnotations(work, oldData.Page, newData.Page);
    }

    private string Squash(PageData data, int from, int count)
    {
        string joined = string.Concat(Enumerable.Range(from, count).Select(data.Word));
        return _options.IgnoreCase ? joined.ToLowerInvariant() : joined;
    }

    private static void CompareSize(PairWork work, PdfPage oldPage, PdfPage newPage)
    {
        var a = new PageGeometry(oldPage);
        var b = new PageGeometry(newPage);
        string? detail = null;
        if (Math.Abs(a.Width - b.Width) > 1 || Math.Abs(a.Height - b.Height) > 1) detail = CompareText.PageSize(a.Width, a.Height, b.Width, b.Height);
        else if (oldPage.Rotate != newPage.Rotate) detail = CompareText.PageRotation(oldPage.Rotate, newPage.Rotate);
        if (detail is null) return;
        work.Others.Add(new CompareChange(ChangeKind.Changed, ChangeArea.Page, work.Pair.OldIndex, work.Pair.NewIndex, "", "",
            [BoxQuad(oldPage.CropBox)], [BoxQuad(newPage.CropBox)], detail));
    }

    /// <summary>
    /// A pure insertion or deletion can often be read several ways ("a b" + "a" after "a" is also "a" + "b a"):
    /// the block slides over equal neighbours. Take the reading whose block starts and ends on line
    /// boundaries, so that the same paragraph looks the same at both ends of a move.
    /// </summary>
    private static SequenceDiff.Hunk Slide(SequenceDiff.Hunk hunk, SequenceDiff.Hunk? previous, SequenceDiff.Hunk? next, PageData oldData, PageData newData)
    {
        bool deletion = hunk.NewCount == 0, insertion = hunk.OldCount == 0;
        if (deletion == insertion) return hunk;
        var ids = deletion ? oldData.Ids : newData.Ids;
        var data = deletion ? oldData : newData;
        int start = deletion ? hunk.OldStart : hunk.NewStart, count = deletion ? hunk.OldCount : hunk.NewCount;

        // The block stays between its neighbours, which it may not overlap.
        int low = previous is { } p ? (deletion ? p.OldStart + p.OldCount : p.NewStart + p.NewCount) : 0;
        int high = next is { } n ? (deletion ? n.OldStart : n.NewStart) : ids.Length;
        int left = 0;
        while (left < MaxSlide && start - left > low && ids[start - left - 1] == ids[start - left + count - 1]) left++;
        int right = 0;
        while (right < MaxSlide && start + right + count < high && ids[start + right] == ids[start + right + count]) right++;
        int best = 0, bestScore = Score(data, start, count);
        for (int shift = -left; shift <= right; shift++)
        {
            int score = Score(data, start + shift, count);
            if (score > bestScore || (score == bestScore && Math.Abs(shift) < Math.Abs(best))) (best, bestScore) = (shift, score);
        }
        return hunk with { OldStart = hunk.OldStart + best, NewStart = hunk.NewStart + best };
    }

    private static int Score(PageData data, int start, int count)
    {
        var words = data.Text.Words;
        bool begins = start == 0 || words[data.Kept[start]].Line != words[data.Kept[start - 1]].Line;
        bool ends = start + count >= data.Kept.Length || words[data.Kept[start + count]].Line != words[data.Kept[start + count - 1]].Line;
        return (begins ? 1 : 0) + (ends ? 1 : 0);
    }

    /// <summary>
    /// A block of at least <see cref="MinMoveWords"/> words that one place lost and another gained,
    /// word for word, was moved. Blocks inside a changed stretch are not looked at.
    /// </summary>
    private static void FindMoves(List<PairWork> work)
    {
        var removed = new Dictionary<string, Queue<TextHunk>>();
        foreach (var hunk in work.SelectMany(w => w.Hunks).Where(h => h.Range.NewCount == 0 && h.Range.OldCount >= MinMoveWords))
        {
            if (!removed.TryGetValue(hunk.Key, out var queue)) removed[hunk.Key] = queue = new Queue<TextHunk>();
            queue.Enqueue(hunk);
        }
        foreach (var hunk in work.SelectMany(w => w.Hunks).Where(h => h.Range.OldCount == 0 && h.Range.NewCount >= MinMoveWords))
        {
            if (!removed.TryGetValue(hunk.Key, out var queue) || queue.Count == 0) continue;
            var source = queue.Dequeue();
            hunk.Partner = source;
            source.Partner = hunk;
        }
    }

    internal static TextQuad BoxQuad(PdfRect r) => new(r.Left, r.Bottom, r.Right, r.Bottom, r.Right, r.Top, r.Left, r.Top);
}
