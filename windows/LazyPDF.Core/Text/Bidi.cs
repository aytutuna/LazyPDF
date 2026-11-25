namespace LazyPDF.Core;

/// <summary>
/// The Unicode Bidirectional Algorithm (UAX #9) for one paragraph of logical text, from the paragraph level
/// (P2, P3, or given) through the explicit levels (X1 to X10), weak types (W1 to W7), paired brackets (N0),
/// neutrals (N1, N2) and implicit levels (I1, I2). Lines are cut afterwards: <see cref="LineLevels"/> applies
/// L1 and <see cref="VisualOrder"/> L2. A paragraph separator may only be the last character.
/// </summary>
internal sealed class BidiParagraph
{
    public const int Auto = -1;
    private const int MaxDepth = 125;
    private const int MaxBracketDepth = 63;

    private readonly int[] cps;
    private readonly int[] unitOf;
    private readonly int[] cpOfUnit;
    private readonly BidiType[] orig;
    private readonly int[] matchingPdi;
    private readonly int[] matchingInitiator;
    private readonly sbyte[] embedding;
    private readonly sbyte[] resolved;

    /// <summary>The paragraph embedding level, 0 or 1.</summary>
    public int Level { get; }

    /// <summary>The resolved level of each UTF-16 unit before line breaking; -1 for characters X9 removes.</summary>
    public sbyte[] Levels { get; }

    /// <param name="baseLevel">0, 1, or <see cref="Auto"/> for the first strong character (P2, P3).</param>
    public BidiParagraph(string text, int baseLevel = Auto)
    {
        var list = new List<int>(text.Length);
        var starts = new List<int>(text.Length + 1);
        cpOfUnit = new int[text.Length + 1];
        for (int i = 0; i < text.Length; i++)
        {
            cpOfUnit[i] = list.Count;
            starts.Add(i);
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                list.Add(char.ConvertToUtf32(text[i], text[i + 1]));
                cpOfUnit[++i] = list.Count - 1;
            }
            else list.Add(text[i]);
        }
        cpOfUnit[text.Length] = list.Count;
        starts.Add(text.Length);
        cps = [.. list];
        unitOf = [.. starts];
        int n = cps.Length;

        orig = new BidiType[n];
        for (int i = 0; i < n; i++) orig[i] = BidiData.TypeOf(cps[i]);
        matchingPdi = new int[n];
        matchingInitiator = new int[n];
        MatchIsolates();

        Level = baseLevel == Auto ? FirstStrong(0, n) : baseLevel & 1;
        embedding = new sbyte[n];
        var types = Explicit();
        resolved = new sbyte[n];
        Implicit(types);

        Levels = new sbyte[text.Length];
        for (int u = 0; u < text.Length; u++) Levels[u] = resolved[cpOfUnit[u]];
    }

    /// <summary>The levels of units <paramref name="start"/> to <paramref name="end"/> of one line, after L1.</summary>
    public sbyte[] LineLevels(int start, int end)
    {
        int c0 = cpOfUnit[start];
        var line = LineLevelsByCode(c0, cpOfUnit[end]);
        var result = new sbyte[end - start];
        for (int u = start; u < end; u++) result[u - start] = line[cpOfUnit[u] - c0];
        return result;
    }

    /// <summary>Unit indices of one line in display order, left to right (L2). Removed characters are left out.</summary>
    public int[] VisualOrder(int start, int end)
    {
        int c0 = cpOfUnit[start], c1 = cpOfUnit[end];
        var line = LineLevelsByCode(c0, c1);
        var order = new List<int>(c1 - c0);
        int highest = 0, lowestOdd = int.MaxValue;
        for (int i = c0; i < c1; i++)
        {
            int l = line[i - c0];
            if (l < 0) continue;
            order.Add(i);
            highest = Math.Max(highest, l);
            if ((l & 1) == 1) lowestOdd = Math.Min(lowestOdd, l);
        }
        for (int l = highest; l >= lowestOdd; l--)
        {
            for (int i = 0; i < order.Count; i++)
            {
                if (line[order[i] - c0] < l) continue;
                int j = i;
                while (j + 1 < order.Count && line[order[j + 1] - c0] >= l) j++;
                order.Reverse(i, j - i + 1);
                i = j;
            }
        }
        var units = new List<int>(end - start);
        foreach (int c in order)
        {
            for (int u = unitOf[c]; u < unitOf[c + 1]; u++) units.Add(u);
        }
        return [.. units];
    }

    private sbyte[] LineLevelsByCode(int c0, int c1)
    {
        var line = new sbyte[c1 - c0];
        bool trailing = true;
        for (int i = c1 - 1; i >= c0; i--)
        {
            sbyte level = resolved[i];
            if (level >= 0)
            {
                var t = orig[i];
                if (t is BidiType.B or BidiType.S)
                {
                    level = (sbyte)Level;
                    trailing = true;
                }
                else if (trailing && t is BidiType.WS or BidiType.FSI or BidiType.LRI or BidiType.RLI or BidiType.PDI) level = (sbyte)Level;
                else trailing = false;
            }
            line[i - c0] = level;
        }
        return line;
    }

    private static bool IsInitiator(BidiType t) => t is BidiType.LRI or BidiType.RLI or BidiType.FSI;

    // BD9
    private void MatchIsolates()
    {
        Array.Fill(matchingPdi, -1);
        Array.Fill(matchingInitiator, -1);
        var open = new Stack<int>();
        for (int i = 0; i < orig.Length; i++)
        {
            if (IsInitiator(orig[i])) open.Push(i);
            else if (orig[i] == BidiType.PDI && open.Count > 0)
            {
                int o = open.Pop();
                matchingPdi[o] = i;
                matchingInitiator[i] = o;
            }
        }
    }

    // P2 and P3 over [from, to): 1 for a right to left first strong character, else 0.
    private int FirstStrong(int from, int to)
    {
        for (int i = from; i < to; i++)
        {
            var t = orig[i];
            if (t == BidiType.L) return 0;
            if (t is BidiType.R or BidiType.AL) return 1;
            if (IsInitiator(t)) i = matchingPdi[i] < 0 ? to : matchingPdi[i];
        }
        return 0;
    }

    // X1 to X8: embedding levels, and the types with directional overrides applied.
    private BidiType[] Explicit()
    {
        int n = orig.Length;
        var types = (BidiType[])orig.Clone();
        var levels = new int[MaxDepth + 2];
        var overrides = new BidiType[MaxDepth + 2];
        var isolate = new bool[MaxDepth + 2];
        int sp = 0;
        levels[0] = Level;
        overrides[0] = BidiType.ON;
        int overflowIsolates = 0, overflowEmbeddings = 0, validIsolates = 0;
        for (int i = 0; i < n; i++)
        {
            var t = orig[i];
            switch (t)
            {
                case BidiType.RLE or BidiType.LRE or BidiType.RLO or BidiType.LRO:
                {
                    embedding[i] = -1;
                    int next = NextLevel(levels[sp], t is BidiType.RLE or BidiType.RLO);
                    if (next <= MaxDepth && overflowIsolates == 0 && overflowEmbeddings == 0)
                    {
                        sp++;
                        levels[sp] = next;
                        overrides[sp] = t == BidiType.RLO ? BidiType.R : t == BidiType.LRO ? BidiType.L : BidiType.ON;
                        isolate[sp] = false;
                    }
                    else if (overflowIsolates == 0) overflowEmbeddings++;
                    break;
                }
                case BidiType.RLI or BidiType.LRI or BidiType.FSI:
                {
                    embedding[i] = (sbyte)levels[sp];
                    if (overrides[sp] != BidiType.ON) types[i] = overrides[sp];
                    bool rtl = t == BidiType.RLI || (t == BidiType.FSI && FirstStrong(i + 1, matchingPdi[i] < 0 ? n : matchingPdi[i]) == 1);
                    int next = NextLevel(levels[sp], rtl);
                    if (next <= MaxDepth && overflowIsolates == 0 && overflowEmbeddings == 0)
                    {
                        validIsolates++;
                        sp++;
                        levels[sp] = next;
                        overrides[sp] = BidiType.ON;
                        isolate[sp] = true;
                    }
                    else overflowIsolates++;
                    break;
                }
                case BidiType.PDI:
                    if (overflowIsolates > 0) overflowIsolates--;
                    else if (validIsolates > 0)
                    {
                        overflowEmbeddings = 0;
                        while (!isolate[sp]) sp--;
                        sp--;
                        validIsolates--;
                    }
                    embedding[i] = (sbyte)levels[sp];
                    if (overrides[sp] != BidiType.ON) types[i] = overrides[sp];
                    break;
                case BidiType.PDF:
                    embedding[i] = -1;
                    if (overflowIsolates > 0) break;
                    if (overflowEmbeddings > 0) overflowEmbeddings--;
                    else if (!isolate[sp] && sp > 0) sp--;
                    break;
                case BidiType.B:
                    embedding[i] = (sbyte)Level;
                    break;
                case BidiType.BN:
                    embedding[i] = -1;
                    break;
                default:
                    embedding[i] = (sbyte)levels[sp];
                    if (overrides[sp] != BidiType.ON) types[i] = overrides[sp];
                    break;
            }
        }
        return types;
    }

    private static int NextLevel(int current, bool rtl) => rtl ? (current + 1) | 1 : (current + 2) & ~1;

    // X9 and X10: drop the removed characters, group the rest into level runs and chain those into
    // isolating run sequences.
    private void Implicit(BidiType[] types)
    {
        int n = cps.Length;
        var kept = new List<int>(n);
        var position = new int[n];
        for (int i = 0; i < n; i++)
        {
            position[i] = -1;
            resolved[i] = -1;
            if (embedding[i] < 0) continue;
            position[i] = kept.Count;
            kept.Add(i);
        }

        var runStart = new List<int>();
        var runOfPosition = new int[kept.Count];
        for (int p = 0; p < kept.Count; p++)
        {
            if (p == 0 || embedding[kept[p]] != embedding[kept[p - 1]]) runStart.Add(p);
            runOfPosition[p] = runStart.Count - 1;
        }
        runStart.Add(kept.Count);

        var sequence = new List<int>();
        for (int r = 0; r + 1 < runStart.Count; r++)
        {
            int first = kept[runStart[r]];
            if (orig[first] == BidiType.PDI && matchingInitiator[first] >= 0) continue;
            sequence.Clear();
            int run = r;
            while (true)
            {
                for (int p = runStart[run]; p < runStart[run + 1]; p++) sequence.Add(kept[p]);
                int last = sequence[^1];
                if (!IsInitiator(orig[last]) || matchingPdi[last] < 0) break;
                run = runOfPosition[position[matchingPdi[last]]];
            }
            ResolveSequence(sequence, types, kept, position);
        }
    }

    private void ResolveSequence(List<int> sequence, BidiType[] types, List<int> kept, int[] position)
    {
        int len = sequence.Count, level = embedding[sequence[0]];
        int before = position[sequence[0]] > 0 ? embedding[kept[position[sequence[0]] - 1]] : Level;
        int lastIndex = sequence[^1];
        int after = IsInitiator(orig[lastIndex]) || position[lastIndex] + 1 >= kept.Count ? Level : embedding[kept[position[lastIndex] + 1]];
        var sos = (Math.Max(level, before) & 1) == 1 ? BidiType.R : BidiType.L;
        var eos = (Math.Max(level, after) & 1) == 1 ? BidiType.R : BidiType.L;

        var w = new BidiType[len];
        for (int k = 0; k < len; k++) w[k] = types[sequence[k]];

        // W1
        for (int k = 0; k < len; k++)
        {
            if (w[k] != BidiType.NSM) continue;
            var prev = k == 0 ? sos : w[k - 1];
            w[k] = IsInitiator(prev) || prev == BidiType.PDI ? BidiType.ON : prev;
        }
        // W2, W3
        var strong = sos;
        for (int k = 0; k < len; k++)
        {
            if (w[k] is BidiType.L or BidiType.R or BidiType.AL) strong = w[k];
            else if (w[k] == BidiType.EN && strong == BidiType.AL) w[k] = BidiType.AN;
        }
        for (int k = 0; k < len; k++)
        {
            if (w[k] == BidiType.AL) w[k] = BidiType.R;
        }
        // W4
        for (int k = 1; k + 1 < len; k++)
        {
            if (w[k] == BidiType.ES && w[k - 1] == BidiType.EN && w[k + 1] == BidiType.EN) w[k] = BidiType.EN;
            else if (w[k] == BidiType.CS && w[k - 1] == w[k + 1] && w[k - 1] is BidiType.EN or BidiType.AN) w[k] = w[k - 1];
        }
        // W5
        for (int k = 0; k < len; k++)
        {
            if (w[k] != BidiType.ET) continue;
            int end = k;
            while (end < len && w[end] == BidiType.ET) end++;
            if ((k > 0 && w[k - 1] == BidiType.EN) || (end < len && w[end] == BidiType.EN))
            {
                for (int j = k; j < end; j++) w[j] = BidiType.EN;
            }
            k = end - 1;
        }
        // W6
        for (int k = 0; k < len; k++)
        {
            if (w[k] is BidiType.ES or BidiType.ET or BidiType.CS) w[k] = BidiType.ON;
        }
        // W7
        strong = sos;
        for (int k = 0; k < len; k++)
        {
            if (w[k] is BidiType.L or BidiType.R) strong = w[k];
            else if (w[k] == BidiType.EN && strong == BidiType.L) w[k] = BidiType.L;
        }

        var dir = (level & 1) == 1 ? BidiType.R : BidiType.L;
        ResolveBrackets(sequence, w, sos, dir);

        // N1, N2
        for (int k = 0; k < len; k++)
        {
            if (!IsNeutral(w[k])) continue;
            int end = k;
            while (end < len && IsNeutral(w[end])) end++;
            var lead = k == 0 ? sos : Direction(w[k - 1]);
            var trail = end == len ? eos : Direction(w[end]);
            var fill = lead == trail ? lead : dir;
            for (int j = k; j < end; j++) w[j] = fill;
            k = end - 1;
        }

        // I1, I2
        for (int k = 0; k < len; k++)
        {
            int l = level;
            if ((level & 1) == 0) l += w[k] == BidiType.R ? 1 : w[k] is BidiType.AN or BidiType.EN ? 2 : 0;
            else if (w[k] is BidiType.L or BidiType.AN or BidiType.EN) l++;
            resolved[sequence[k]] = (sbyte)l;
        }
    }

    private static bool IsNeutral(BidiType t) =>
        t is BidiType.B or BidiType.S or BidiType.WS or BidiType.ON or BidiType.FSI or BidiType.LRI or BidiType.RLI or BidiType.PDI;

    // L for L, R for R and for numbers.
    private static BidiType Direction(BidiType t) => t == BidiType.L ? BidiType.L : BidiType.R;

    private static BidiType StrongOrNeutral(BidiType t) =>
        t == BidiType.L ? BidiType.L : t is BidiType.R or BidiType.EN or BidiType.AN ? BidiType.R : BidiType.ON;

    // U+2329 and U+232A are canonically equivalent to U+3008 and U+3009 (BD16).
    private static int Canonical(int cp) => cp switch { 0x2329 => 0x3008, 0x232A => 0x3009, _ => cp };

    // BD16 and N0.
    private void ResolveBrackets(List<int> sequence, BidiType[] w, BidiType sos, BidiType dir)
    {
        int len = w.Length;
        var openers = new List<(int Closer, int Index)>();
        var pairs = new List<(int Open, int Close)>();
        for (int k = 0; k < len; k++)
        {
            if (w[k] != BidiType.ON) continue;
            int cp = cps[sequence[k]];
            int paired = BidiData.PairedBracket(cp, out bool opening);
            if (paired == 0) continue;
            if (opening)
            {
                if (openers.Count == MaxBracketDepth) break;
                openers.Add((Canonical(paired), k));
                continue;
            }
            int canonical = Canonical(cp);
            for (int s = openers.Count - 1; s >= 0; s--)
            {
                if (openers[s].Closer != canonical) continue;
                pairs.Add((openers[s].Index, k));
                openers.RemoveRange(s, openers.Count - s);
                break;
            }
        }
        pairs.Sort((a, b) => a.Open.CompareTo(b.Open));

        var opposite = dir == BidiType.L ? BidiType.R : BidiType.L;
        foreach (var (open, close) in pairs)
        {
            bool foundDir = false, foundOpposite = false;
            for (int k = open + 1; k < close; k++)
            {
                var s = StrongOrNeutral(w[k]);
                if (s == dir)
                {
                    foundDir = true;
                    break;
                }
                if (s == opposite) foundOpposite = true;
            }
            BidiType to;
            if (foundDir) to = dir;
            else if (foundOpposite)
            {
                var context = sos;
                for (int k = open - 1; k >= 0; k--)
                {
                    var s = StrongOrNeutral(w[k]);
                    if (s == BidiType.ON) continue;
                    context = s;
                    break;
                }
                to = context == opposite ? opposite : dir;
            }
            else continue;
            SetBracket(sequence, w, open, to);
            SetBracket(sequence, w, close, to);
        }
    }

    // Characters that were NSM before W1 and follow a bracket take its new direction.
    private void SetBracket(List<int> sequence, BidiType[] w, int k, BidiType to)
    {
        w[k] = to;
        for (int j = k + 1; j < w.Length && orig[sequence[j]] == BidiType.NSM; j++) w[j] = to;
    }
}
