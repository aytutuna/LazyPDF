namespace LazyPDF.Core;

// Judges what the updates after a signature changed. UpdateGate has already shown that the bytes are exact; here
// each object an update lists is compared with its signed copy and judged by what the signed revision used it for
// (Jobs). An object with more than one job, a new object nothing allowed reaches, a freed object something still
// names, a changed generation: none of these is allowed. What the rules do not name is not allowed.
internal sealed partial class ChangeDetector
{
    private static readonly SignatureChangeReport Unreadable = new([new SignatureChange(SignatureChangeKind.Unreadable, 0, -1, null, false)], 0);

    private readonly PdfDocument _a;
    private readonly PdfDocument _b;
    private readonly int _level;
    private readonly IReadOnlySet<long> _signatures;
    private readonly Jobs _jobsA;
    private readonly Jobs _jobsB;
    private readonly List<SignatureChange> _changes = [];
    private readonly List<(FieldLockAction Action, HashSet<string> Names)> _locks = [];
    private Dictionary<int, int>? _references;
    private Dictionary<int, int>? _signedReferences;

    private ChangeDetector(PdfDocument before, PdfDocument after, int level, IReadOnlySet<long> signatures)
    {
        _a = before;
        _b = after;
        _level = level;
        _signatures = signatures;
        _jobsA = new Jobs(before);
        _jobsB = new Jobs(after);
        ReadLocks();
    }

    /// <summary>
    /// The changes from <paramref name="before"/>, the file cut at the end of the signed bytes, to <paramref name="after"/>
    /// judged at <paramref name="level"/>: 0 for a file that is not certified, else the /DocMDP permission 1 to 3.
    /// <paramref name="signatures"/> are the offsets of the signature objects in the file whose byte range is sound: only
    /// those make a new signature field real. Bytes that cannot all be placed exactly are one change that is not allowed.
    /// </summary>
    public static SignatureChangeReport Compare(PdfDocument before, PdfDocument after, int level, IReadOnlySet<long> signatures)
    {
        try
        {
            if (UpdateGate.Check(before, after) is not { } listing) return Unreadable;
            var detector = new ChangeDetector(before, after, level, signatures);
            // Jobs the walk did not reach are jobs nothing will judge.
            if (!detector._jobsA.Complete || !detector._jobsB.Complete) return Unreadable;
            detector.Run(listing);
            // The documents repair as objects are read; a repair the signed revision did not need means a table was not trusted.
            if (after.Repairs.Except(before.Repairs).Any()) detector.Report(SignatureChangeKind.Unreadable, 0, allowed: false);
            return new SignatureChangeReport(detector._changes, 0);
        }
        catch (PdfReadException)
        {
            return Unreadable;
        }
    }

    private bool Permits(SignatureChangeKind kind) => kind switch
    {
        SignatureChangeKind.ValidationData => true,
        SignatureChangeKind.Signature => _level != 1,
        SignatureChangeKind.FormFill => _level >= 2,
        SignatureChangeKind.Comment => _level == 3,
        SignatureChangeKind.Metadata => _level >= 2,
        _ => false,
    };

    private void Report(SignatureChangeKind kind, int number, int page = -1, string? field = null, bool? allowed = null) =>
        _changes.Add(new SignatureChange(kind, number, page, field, allowed ?? Permits(kind)));

    private static bool IsListed(PdfDocument.Entry entry) => entry.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed;

    private void Run(UpdateGate.Listing listing)
    {
        foreach (int n in listing.Touched.Order())
        {
            _a.Entries.TryGetValue(n, out var before);
            _b.Entries.TryGetValue(n, out var after);
            // A cross-reference or object stream an update writes is only plumbing while nothing refers to it: its bytes
            // are not an object then, and its members are judged one by one. A number the signed revision named is judged as any.
            if (listing.Plumbing.Contains(n) && !IsListed(before) && !References().ContainsKey(n)) continue;
            if (IsListed(before) && IsListed(after))
            {
                if (before.Generation != after.Generation) Denied(n, _jobsA.Of(n));
                else if (_a.Get(n) is { } x && _b.Get(n) is { } y && !Same(x, y)) Modified(n, x, y);
            }
            else if (IsListed(after))
            {
                Added(n);
            }
            else if (IsListed(before))
            {
                Removed(n);
            }
            else if (listing.Defined.Contains(n) && References().ContainsKey(n))
            {
                // Given an object and freed again, the reference that was dangling in the signed revision is still there for a scanning viewer to fill.
                Denied(n, _jobsB.Of(n));
            }
        }
    }

    private bool Same(PdfObject a, PdfObject b)
    {
        if (a is PdfStream sa && b is PdfStream sb) return Text(sa.Dictionary) == Text(sb.Dictionary) && _a.RawData(sa).AsSpan().SequenceEqual(_b.RawData(sb));
        return a.GetType() == b.GetType() && Text(a) == Text(b);
    }

    // The one kind of use an object has, or null when it has none or several.
    private static JobKind? OnlyKind(IEnumerable<Job> jobs)
    {
        var kinds = jobs.Select(j => j.Kind).Distinct().Take(2).ToList();
        return kinds.Count == 1 ? kinds[0] : null;
    }

    private static int PageOf(IEnumerable<Job> jobs) => jobs.Select(j => j.Page).FirstOrDefault(p => p >= 0, -1);

    private void Denied(int n, IEnumerable<Job> jobs)
    {
        var kinds = jobs.Select(j => j.Kind).ToHashSet();
        var kind = kinds.Contains(JobKind.Content) ? SignatureChangeKind.PageContent
            : kinds.Overlaps([JobKind.Page, JobKind.PageTree, JobKind.Catalog]) ? SignatureChangeKind.PageStructure
            : kinds.Overlaps([JobKind.Form, JobKind.FieldList, JobKind.Field, JobKind.Defaults]) ? SignatureChangeKind.Form
            : SignatureChangeKind.Other;
        Report(kind, n, PageOf(jobs), allowed: false);
    }

    private void Modified(int n, PdfObject before, PdfObject after)
    {
        var jobs = _jobsA.Of(n).Union(_jobsB.Of(n)).ToList();
        if (OnlyKind(jobs) is not { } kind || kind is JobKind.Field or JobKind.Dss or JobKind.Defaults && jobs.Select(j => j.Owner).Distinct().Count() > 1)
        {
            Denied(n, jobs);
            return;
        }
        int page = PageOf(jobs);
        var (a, b) = (before as PdfDictionary, after as PdfDictionary);
        switch (kind)
        {
            case JobKind.Catalog when a is not null && b is not null:
                Catalog(n, a, b);
                break;
            case JobKind.Form when a is not null && b is not null:
                AcroForm(n, a, b);
                break;
            case JobKind.Page when a is not null && b is not null:
                Page(n, page, a, b);
                break;
            case JobKind.Field when a is not null && b is not null:
                Field(n, _jobsA.Fields.GetValueOrDefault(jobs[0].Owner), a, b);
                break;
            case JobKind.Comment when a is not null && b is not null:
                Comment(n, page, a, b);
                break;
            case JobKind.FieldList when before is PdfArray fa && after is PdfArray fb:
                FieldsDiff(fa.Items, fb.Items);
                break;
            case JobKind.AnnotList when before is PdfArray aa && after is PdfArray ab:
                AnnotsDiff(aa.Items, ab.Items, page);
                break;
            case JobKind.Appearance or JobKind.Value:
                foreach (var job in jobs.DistinctBy(j => j.Owner)) Part(n, job, added: false);
                break;
            case JobKind.Info when before is PdfStream sa && after is PdfStream sb:
                Packet(n, sa, sb);
                break;
            case JobKind.Info:
                Information(n, a, b);
                break;
            case JobKind.Defaults:
                Report(SignatureChangeKind.FormFill, n, allowed: DefaultsAllowed(a is not null && b is not null && Grew(a, b, jobs[0].Owner)));
                break;
            case JobKind.Dss:
                Validation(n, jobs[0].Owner, before, after);
                break;
            default:
                Denied(n, jobs);
                break;
        }
    }

    // A new object is allowed only for the use the update gives it, and only where that use may be added.
    private void Added(int n)
    {
        var jobs = _jobsB.Of(n);
        // A font the form's defaults gain is the one its new appearance draws with. A new object changes how a signed one
        // draws only through a changed object that names it, which is judged on its own, unless the signed revision named
        // a number nothing was at.
        if (jobs.Any(j => j.Kind == JobKind.Defaults) && jobs.All(j => j.Kind is JobKind.Defaults or JobKind.Appearance))
        {
            Report(SignatureChangeKind.FormFill, n, allowed: DefaultsAllowed(!SignedReferences().ContainsKey(n)));
            foreach (var job in jobs.Where(j => j.Kind == JobKind.Appearance).DistinctBy(j => j.Owner)) Part(n, job, added: true);
            return;
        }
        if (OnlyKind(jobs) is not { } kind)
        {
            Denied(n, jobs);
            return;
        }
        int page = PageOf(jobs);
        switch (kind)
        {
            case JobKind.Comment:
                AddedComment(n, page);
                break;
            case JobKind.Field:
                AddedField(n, page);
                break;
            case JobKind.Appearance or JobKind.Value:
                foreach (var job in jobs.DistinctBy(j => j.Owner)) Part(n, job, added: true);
                break;
            case JobKind.Info:
                Information(n, new PdfDictionary(), _b.Get(n) as PdfDictionary);
                break;
            case JobKind.Dss:
                Report(SignatureChangeKind.ValidationData, n);
                break;
            case JobKind.AnnotList when _b.Get(n) is PdfArray items:
                AnnotsDiff([], items.Items, page);
                break;
            case JobKind.FieldList when _b.Get(n) is PdfArray items:
                FieldsDiff([], items.Items);
                break;
            case JobKind.Form when _b.Get(n) is PdfDictionary form:
                AcroForm(n, new PdfDictionary(), form);
                break;
            default:
                Denied(n, jobs);
                break;
        }
    }

    private void Removed(int n)
    {
        var jobs = _jobsA.Of(n);
        // A name that is still written down somewhere would read as nothing there.
        if (References().ContainsKey(n) || OnlyKind(jobs) is not { } kind)
        {
            Denied(n, jobs);
            return;
        }
        switch (kind)
        {
            case JobKind.Comment or JobKind.AnnotList:
                Report(SignatureChangeKind.Comment, n, PageOf(jobs));
                break;
            case JobKind.Appearance when jobs.All(j => j.Owner == 0):
                Report(SignatureChangeKind.Comment, n, PageOf(jobs));
                break;
            case JobKind.Info:
                Report(SignatureChangeKind.Metadata, n);
                break;
            case JobKind.Dss:
                Report(SignatureChangeKind.ValidationData, n);
                break;
            default:
                Denied(n, jobs);
                break;
        }
    }

    // How often each number is written as a reference anywhere in the file as it is, in objects nothing reaches too.
    private Dictionary<int, int> References() => _references ??= CountReferences(_b);

    private Dictionary<int, int> SignedReferences() => _signedReferences ??= CountReferences(_a);

    private static Dictionary<int, int> CountReferences(PdfDocument document)
    {
        var counts = new Dictionary<int, int>();
        foreach (var r in ReferencesIn(document.Trailer)) counts[r.Number] = counts.GetValueOrDefault(r.Number) + 1;
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not { } value) continue;
            foreach (var r in ReferencesIn(value)) counts[r.Number] = counts.GetValueOrDefault(r.Number) + 1;
        }
        return counts;
    }

    private static IEnumerable<PdfReference> ReferencesIn(PdfObject value)
    {
        var pending = new Stack<PdfObject>();
        pending.Push(value);
        while (pending.Count > 0)
        {
            switch (pending.Pop())
            {
                case PdfReference r:
                    yield return r;
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) pending.Push(item);
                    break;
                case PdfDictionary dictionary:
                    foreach (var (_, item) in dictionary.Entries) pending.Push(item);
                    break;
                case PdfStream stream:
                    pending.Push(stream.Dictionary);
                    break;
            }
        }
    }
}
