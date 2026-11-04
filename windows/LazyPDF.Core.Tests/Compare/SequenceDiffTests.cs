using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SequenceDiffTests
{
    private static int[] Apply(int[] a, int[] b, List<SequenceDiff.Hunk> hunks)
    {
        var result = new List<int>();
        int at = 0;
        foreach (var h in hunks)
        {
            result.AddRange(a[at..h.OldStart]);
            result.AddRange(b[h.NewStart..(h.NewStart + h.NewCount)]);
            at = h.OldStart + h.OldCount;
        }
        result.AddRange(a[at..]);
        return [.. result];
    }

    [Fact]
    public void EqualSequencesHaveNoHunks() => Assert.Empty(SequenceDiff.Diff([1, 2, 3], [1, 2, 3]));

    [Fact]
    public void OneSideEmptyIsOneHunk()
    {
        Assert.Equal([new SequenceDiff.Hunk(0, 0, 0, 3)], SequenceDiff.Diff([], [1, 2, 3]));
        Assert.Equal([new SequenceDiff.Hunk(0, 3, 0, 0)], SequenceDiff.Diff([1, 2, 3], []));
    }

    [Fact]
    public void ReplacementInTheMiddleIsOneHunk() =>
        Assert.Equal([new SequenceDiff.Hunk(2, 1, 2, 2)], SequenceDiff.Diff([1, 2, 3, 4, 5], [1, 2, 8, 9, 4, 5]));

    [Fact]
    public void SeparateEditsAreSeparateHunks()
    {
        var hunks = SequenceDiff.Diff([1, 2, 3, 4, 5, 6, 7], [1, 9, 3, 4, 5, 7]);
        Assert.Equal([new SequenceDiff.Hunk(1, 1, 1, 1), new SequenceDiff.Hunk(5, 1, 5, 0)], hunks);
    }

    [Fact]
    public void HunksRebuildTheNewSequenceAndAreMinimal()
    {
        var random = new Random(7);
        for (int round = 0; round < 300; round++)
        {
            int[] a = [.. Enumerable.Range(0, random.Next(0, 40)).Select(_ => random.Next(0, 6))];
            int[] b = [.. Enumerable.Range(0, random.Next(0, 40)).Select(_ => random.Next(0, 6))];
            var hunks = SequenceDiff.Diff(a, b);
            Assert.Equal(b, Apply(a, b, hunks));
            int edits = hunks.Sum(h => h.OldCount + h.NewCount);
            Assert.Equal(a.Length + b.Length - 2 * Lcs(a, b), edits);
        }
    }

    [Fact]
    public void PastTheEditCapTheMiddleIsOneHunk()
    {
        int[] a = [.. Enumerable.Range(0, 400).Select(i => i * 2)];
        int[] b = [.. Enumerable.Range(0, 400).Select(i => i * 2 + 1)];
        var hunks = SequenceDiff.Diff(a, b, 50);
        Assert.Equal([new SequenceDiff.Hunk(0, 400, 0, 400)], hunks);
    }

    [Fact]
    public void CommonEndsAreTrimmedBeforeTheCapApplies()
    {
        int[] a = [.. Enumerable.Range(0, 5000), 1000000, .. Enumerable.Range(0, 5000)];
        int[] b = [.. Enumerable.Range(0, 5000), 2000000, .. Enumerable.Range(0, 5000)];
        Assert.Equal([new SequenceDiff.Hunk(5000, 1, 5000, 1)], SequenceDiff.Diff(a, b, 10));
    }

    private static int Lcs(int[] a, int[] b)
    {
        var t = new int[a.Length + 1, b.Length + 1];
        for (int i = 1; i <= a.Length; i++)
        {
            for (int j = 1; j <= b.Length; j++) t[i, j] = a[i - 1] == b[j - 1] ? t[i - 1, j - 1] + 1 : Math.Max(t[i - 1, j], t[i, j - 1]);
        }
        return t[a.Length, b.Length];
    }
}
