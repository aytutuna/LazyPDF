namespace LazyPDF.Core;

/// <summary>
/// Pairs the pages of two files by what is on them. The pairs that keep their order and add up to the
/// most similarity are found first (a weighted longest increasing subsequence), then the pages left
/// over are paired as moved when they are alike, and what remains between two anchors is paired in order.
/// </summary>
internal static class PageAligner
{
    public const double MatchThreshold = 0.5;
    private const double GapThreshold = 0.15;
    private const int MaxPostings = 64;
    private const int TopCandidates = 8;
    private const int SameHashCandidates = 4;
    private const double PoorWeight = 0.01;
    private const int MaxGapCells = 40_000;

    /// <summary>
    /// A page signature is the sorted distinct hashes of its word pairs (and pictures); a page with
    /// little text (a scan, a slide) is paired with whatever stands in its gap, since words cannot tell it apart.
    /// </summary>
    public static List<PagePair> Align(IReadOnlyList<int[]> before, IReadOnlyList<int[]> after, IReadOnlyList<bool> oldPoor, IReadOnlyList<bool> newPoor, CancellationToken cancellation)
    {
        var candidates = Candidates(before, after, MatchThreshold, cancellation);
        var anchors = Chain(candidates, after.Count);
        var oldTo = new int[before.Count];
        var newTo = new int[after.Count];
        Array.Fill(oldTo, -1);
        Array.Fill(newTo, -1);
        foreach (var c in anchors)
        {
            oldTo[c.Old] = c.New;
            newTo[c.New] = c.Old;
        }
        var movedNew = new HashSet<int>();
        foreach (var c in candidates.Where(c => oldTo[c.Old] < 0 && newTo[c.New] < 0).OrderByDescending(c => c.Similarity).ThenBy(c => Math.Abs(c.Old - c.New)))
        {
            if (oldTo[c.Old] >= 0 || newTo[c.New] >= 0) continue;
            oldTo[c.Old] = c.New;
            newTo[c.New] = c.Old;
            movedNew.Add(c.New);
        }

        var result = new List<PagePair>();
        int oi = 0, nj = 0;
        foreach (var anchor in anchors.OrderBy(a => a.Old).Append(new Candidate(before.Count, after.Count, 0)))
        {
            var freeOld = Enumerable.Range(oi, anchor.Old - oi).Where(i => oldTo[i] < 0).ToList();
            var freeNew = Enumerable.Range(nj, anchor.New - nj).Where(j => newTo[j] < 0).ToList();
            var paired = Gap(freeOld, freeNew, before, after, oldPoor, newPoor, cancellation);
            foreach (int i in freeOld.Where(i => !paired.ContainsValue(i))) result.Add(new PagePair(i, -1, 0, false));
            for (int j = nj; j < anchor.New; j++)
            {
                if (paired.TryGetValue(j, out int old)) result.Add(new PagePair(old, j, Dice(before[old], after[j]), false));
                else if (newTo[j] >= 0) result.Add(new PagePair(newTo[j], j, Dice(before[newTo[j]], after[j]), movedNew.Contains(j)));
                else result.Add(new PagePair(-1, j, 0, false));
            }
            if (anchor.Old < before.Count) result.Add(new PagePair(anchor.Old, anchor.New, anchor.Similarity, false));
            oi = anchor.Old + 1;
            nj = anchor.New + 1;
        }
        return result;
    }

    /// <summary>
    /// The pages left between two anchors, paired in order by the pairing of most similarity, so that one
    /// inserted page does not cancel the rest. Pages of equal weight pair with the earliest partner.
    /// A gap too big for the full table is split first at the pages that share enough words, wherever they stand.
    /// </summary>
    private static Dictionary<int, int> Gap(List<int> freeOld, List<int> freeNew, IReadOnlyList<int[]> before, IReadOnlyList<int[]> after,
        IReadOnlyList<bool> oldPoor, IReadOnlyList<bool> newPoor, CancellationToken cancellation)
    {
        var paired = new Dictionary<int, int>();
        double Weight(int i, int j)
        {
            double dice = Dice(before[i], after[j]);
            if (dice >= GapThreshold) return dice;
            return oldPoor[i] && newPoor[j] ? PoorWeight : 0;
        }

        void Table(List<int> oldPages, List<int> newPages)
        {
            int n = oldPages.Count, m = newPages.Count;
            if (n == 0 || m == 0) return;
            var best = new double[n + 1, m + 1];
            for (int a = n - 1; a >= 0; a--)
            {
                cancellation.ThrowIfCancellationRequested();
                for (int b = m - 1; b >= 0; b--)
                    best[a, b] = Math.Max(best[a + 1, b], Math.Max(best[a, b + 1], best[a + 1, b + 1] + Weight(oldPages[a], newPages[b])));
            }
            for (int a = 0, b = 0; a < n && b < m;)
            {
                double w = Weight(oldPages[a], newPages[b]);
                if (w > 0 && best[a, b] == best[a + 1, b + 1] + w)
                {
                    paired[newPages[b]] = oldPages[a];
                    a++;
                    b++;
                }
                else if (best[a, b] == best[a + 1, b]) a++;
                else b++;
            }
        }

        // What the chain left between its pairs has no page alike on both sides. Pages with no words to tell
        // them apart (scans) pair by position when the counts agree.
        void Rest(List<int> oldPages, List<int> newPages)
        {
            if ((long)oldPages.Count * newPages.Count <= MaxGapCells) Table(oldPages, newPages);
            else if (oldPages.Count == newPages.Count)
            {
                for (int a = 0; a < oldPages.Count; a++)
                {
                    if (Weight(oldPages[a], newPages[a]) > 0) paired[newPages[a]] = oldPages[a];
                }
            }
        }

        if ((long)freeOld.Count * freeNew.Count <= MaxGapCells)
        {
            Table(freeOld, freeNew);
            return paired;
        }
        var candidates = Candidates([.. freeOld.Select(i => before[i])], [.. freeNew.Select(j => after[j])], GapThreshold, cancellation);
        int a0 = 0, b0 = 0;
        foreach (var c in Chain(candidates, freeNew.Count))
        {
            Rest(freeOld.GetRange(a0, c.Old - a0), freeNew.GetRange(b0, c.New - b0));
            paired[freeNew[c.New]] = freeOld[c.Old];
            a0 = c.Old + 1;
            b0 = c.New + 1;
        }
        Rest(freeOld.GetRange(a0, freeOld.Count - a0), freeNew.GetRange(b0, freeNew.Count - b0));
        return paired;
    }

    private readonly record struct Candidate(int Old, int New, double Similarity);

    private static List<Candidate> Candidates(IReadOnlyList<int[]> before, IReadOnlyList<int[]> after, double threshold, CancellationToken cancellation)
    {
        var index = new Dictionary<int, List<int>>();
        var byHash = new Dictionary<long, List<int>>();
        for (int i = 0; i < before.Count; i++)
        {
            foreach (int s in before[i])
            {
                if (!index.TryGetValue(s, out var list)) index[s] = list = [];
                list.Add(i);
            }
            if (!byHash.TryGetValue(Hash(before[i]), out var same)) byHash[Hash(before[i])] = same = [];
            same.Add(i);
        }

        var result = new List<Candidate>();
        for (int j = 0; j < after.Count; j++)
        {
            cancellation.ThrowIfCancellationRequested();
            var chosen = new HashSet<int>();
            var overlap = new Dictionary<int, int>();
            foreach (int s in after[j])
            {
                if (!index.TryGetValue(s, out var list) || list.Count > MaxPostings) continue;
                foreach (int i in list) overlap[i] = overlap.GetValueOrDefault(i) + 1;
            }
            chosen.UnionWith(overlap.OrderByDescending(p => p.Value).ThenBy(p => Math.Abs(p.Key - j)).Take(TopCandidates).Select(p => p.Key));
            if (byHash.TryGetValue(Hash(after[j]), out var identical)) chosen.UnionWith(identical.OrderBy(i => Math.Abs(i - j)).Take(SameHashCandidates));
            for (int i = Math.Max(0, j - 1); i <= Math.Min(before.Count - 1, j + 1); i++) chosen.Add(i);
            foreach (int i in chosen)
            {
                double similarity = Dice(before[i], after[j]);
                if (similarity >= threshold) result.Add(new Candidate(i, j, similarity));
            }
        }
        return result;
    }

    /// <summary>The order-keeping subset with the largest total similarity: for each old page in turn, the best chain ending left of its partner.</summary>
    private static List<Candidate> Chain(List<Candidate> candidates, int newCount)
    {
        var sorted = candidates.OrderBy(c => c.Old).ThenBy(c => c.New).ToList();
        var best = new double[sorted.Count];
        var previous = new int[sorted.Count];
        var tree = new (double Weight, int Item)[newCount + 2];
        Array.Fill(tree, (0.0, -1));
        int winner = -1;
        for (int start = 0; start < sorted.Count;)
        {
            int end = start;
            while (end < sorted.Count && sorted[end].Old == sorted[start].Old) end++;
            for (int k = start; k < end; k++)
            {
                var (weight, item) = Query(tree, sorted[k].New);
                best[k] = weight + sorted[k].Similarity;
                previous[k] = item;
                if (winner < 0 || best[k] > best[winner]) winner = k;
            }
            for (int k = start; k < end; k++) Update(tree, sorted[k].New + 1, best[k], k);
            start = end;
        }
        var chain = new List<Candidate>();
        for (int k = winner; k >= 0; k = previous[k]) chain.Add(sorted[k]);
        chain.Reverse();
        return chain;
    }

    /// <summary>The best entry among new pages below <paramref name="newIndex"/>.</summary>
    private static (double, int) Query((double Weight, int Item)[] tree, int newIndex)
    {
        var best = (0.0, -1);
        for (int p = newIndex; p > 0; p -= p & -p)
        {
            if (tree[p].Weight > best.Item1) best = tree[p];
        }
        return best;
    }

    private static void Update((double Weight, int Item)[] tree, int position, double weight, int item)
    {
        for (int p = position; p < tree.Length; p += p & -p)
        {
            if (weight > tree[p].Weight) tree[p] = (weight, item);
        }
    }

    public static double Dice(int[] a, int[] b)
    {
        if (a.Length == 0 && b.Length == 0) return 1;
        if (a.Length == 0 || b.Length == 0) return 0;
        int i = 0, j = 0, common = 0;
        while (i < a.Length && j < b.Length)
        {
            if (a[i] == b[j])
            {
                common++;
                i++;
                j++;
            }
            else if (a[i] < b[j]) i++;
            else j++;
        }
        return 2.0 * common / (a.Length + b.Length);
    }

    private static long Hash(int[] signature)
    {
        long h = 17 + signature.Length;
        foreach (int s in signature) h = h * 1_000_003 + s;
        return h;
    }
}
