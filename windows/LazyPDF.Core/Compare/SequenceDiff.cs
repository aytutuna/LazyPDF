namespace LazyPDF.Core;

/// <summary>Shortest edit script of two int sequences (Myers, "An O(ND) difference algorithm", 1986).</summary>
internal static class SequenceDiff
{
    /// <summary>The old items <c>[OldStart, OldStart + OldCount)</c> became the new items <c>[NewStart, NewStart + NewCount)</c>.</summary>
    public readonly record struct Hunk(int OldStart, int OldCount, int NewStart, int NewCount);

    /// <summary>
    /// The places where the sequences differ. Past <paramref name="maxEdits"/> edits in the part
    /// between the common ends the search stops and that part is one hunk, which bounds the memory
    /// at about maxEdits squared ints.
    /// </summary>
    public static List<Hunk> Diff(ReadOnlySpan<int> a, ReadOnlySpan<int> b, int maxEdits = 2000)
    {
        int head = 0;
        while (head < a.Length && head < b.Length && a[head] == b[head]) head++;
        int tail = 0;
        while (tail < a.Length - head && tail < b.Length - head && a[^(tail + 1)] == b[^(tail + 1)]) tail++;
        var middleA = a[head..(a.Length - tail)];
        var middleB = b[head..(b.Length - tail)];
        var hunks = new List<Hunk>();
        if (middleA.Length == 0 && middleB.Length == 0) return hunks;
        if (middleA.Length == 0 || middleB.Length == 0 || !TryMyers(middleA, middleB, maxEdits, hunks))
        {
            hunks.Clear();
            hunks.Add(new Hunk(0, middleA.Length, 0, middleB.Length));
        }
        for (int i = 0; i < hunks.Count; i++) hunks[i] = hunks[i] with { OldStart = hunks[i].OldStart + head, NewStart = hunks[i].NewStart + head };
        return hunks;
    }

    private static bool TryMyers(ReadOnlySpan<int> a, ReadOnlySpan<int> b, int maxEdits, List<Hunk> hunks)
    {
        int n = a.Length, m = b.Length;
        int max = Math.Min(n + m, maxEdits);
        int offset = max + 1;
        var v = new int[2 * max + 3];
        var trace = new List<int[]>();
        int found = -1;
        for (int d = 0; d <= max && found < 0; d++)
        {
            for (int k = -d; k <= d; k += 2)
            {
                int x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
                int y = x - k;
                while (x < n && y < m && a[x] == b[y])
                {
                    x++;
                    y++;
                }
                v[offset + k] = x;
                if (x >= n && y >= m)
                {
                    found = d;
                    break;
                }
            }
            trace.Add(v[(offset - d)..(offset + d + 1)]);
        }
        if (found < 0) return false;

        var edits = new List<(int X, int Y, bool Delete)>();
        int px = n, py = m;
        for (int d = found; d > 0; d--)
        {
            var previous = trace[d - 1];
            int k = px - py;
            int at(int diagonal) => previous[diagonal + d - 1];
            int previousK = k == -d || (k != d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
            int x = at(previousK), y = x - previousK;
            edits.Add(previousK == k + 1 ? (x, y, false) : (x, y, true));
            (px, py) = (x, y);
        }
        edits.Reverse();

        int endX = -1, endY = -1;
        Hunk current = default;
        foreach (var (x, y, delete) in edits)
        {
            if (x != endX || y != endY)
            {
                if (endX >= 0) hunks.Add(current);
                current = new Hunk(x, 0, y, 0);
            }
            current = delete ? current with { OldCount = current.OldCount + 1 } : current with { NewCount = current.NewCount + 1 };
            (endX, endY) = delete ? (x + 1, y) : (x, y + 1);
        }
        if (endX >= 0) hunks.Add(current);
        return true;
    }
}
