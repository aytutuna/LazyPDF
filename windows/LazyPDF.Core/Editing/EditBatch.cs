using System.Text;

namespace LazyPDF.Core;

/// <summary>A change that cannot be made as asked, found before anything was written.</summary>
internal sealed class EditConflictException(string message) : Exception(message);

/// <summary>A content stream and the run of it an edit is about.</summary>
internal readonly record struct Place(ContentUnit Unit, FormVisit? Visit)
{
    /// <summary>The scan of this run: a form painted twice starts from the state of each <c>Do</c>.</summary>
    public OpStates States => Visit?.States ?? Unit.States;
}

/// <summary>
/// The changes of one edit, gathered and then written to the document together: cuts in content
/// streams, new resources, content added at the end of the page. A form XObject that something else
/// also uses is copied and only the <c>Do</c> that was edited is pointed at the copy; one that
/// nothing else uses is edited in place. Content streams of the page are rewritten one by one, so
/// a stream the edit does not touch stays the object it was.
/// </summary>
internal sealed class EditBatch(PdfDocument document, PdfPage page, EditScan scan)
{
    private readonly int _firstObject = document.NextObjectNumber;

    private sealed class UnitEdit(ContentUnit unit, FormVisit? visit)
    {
        public ContentUnit Unit { get; } = unit;
        public FormVisit? Visit { get; } = visit;
        public Dictionary<int, ShowPatch> Patches { get; } = [];
        public List<Splice> Splices { get; } = [];
        public List<Resource> Resources { get; } = [];
        public int Depth => Visit?.Chain.Count ?? 0;
    }

    private sealed class Resource(string category, string name, Func<PdfObject> value)
    {
        public string Category { get; } = category;
        public string Name { get; } = name;
        public Func<PdfObject> Value { get; } = value;
    }

    private sealed class Work(UnitEdit edit, byte[] data, bool copy)
    {
        public UnitEdit Edit { get; } = edit;
        public byte[] Data { get; } = data;
        public bool Copy { get; } = copy;
        public PdfReference? Reference { get; set; }
        public PagePlan? Plan { get; set; }
    }

    private sealed record PagePlan(List<Part> Parts, List<Splice> Splices, List<(int Lo, int Hi)> Groups);

    private readonly Dictionary<ContentUnit, UnitEdit> _edits = [];
    private readonly List<byte[]> _appended = [];
    private HashSet<string>? _names;
    private Dictionary<int, int>? _references;

    public bool IsEmpty => _edits.Count == 0 && _appended.Count == 0;

    /// <summary>Where the batch stands, to take back what a failed step added.</summary>
    public sealed class Mark
    {
        internal Dictionary<ContentUnit, (int Splices, int Resources, Dictionary<int, (int Cuts, int Inserts)> Patches)> Units { get; } = [];
        internal int Appended { get; init; }
        internal int Objects { get; init; }
    }

    public Mark Save()
    {
        var mark = new Mark { Appended = _appended.Count, Objects = document.NextObjectNumber };
        foreach (var (unit, edit) in _edits)
        {
            mark.Units[unit] = (edit.Splices.Count, edit.Resources.Count, edit.Patches.ToDictionary(p => p.Key, p => p.Value.Count));
        }
        return mark;
    }

    public void Restore(Mark mark)
    {
        foreach (var unit in _edits.Keys.Where(u => !mark.Units.ContainsKey(u)).ToList()) _edits.Remove(unit);
        foreach (var (unit, saved) in mark.Units)
        {
            var edit = _edits[unit];
            edit.Splices.RemoveRange(saved.Splices, edit.Splices.Count - saved.Splices);
            edit.Resources.RemoveRange(saved.Resources, edit.Resources.Count - saved.Resources);
            foreach (var op in edit.Patches.Keys.Where(k => !saved.Patches.ContainsKey(k)).ToList()) edit.Patches.Remove(op);
            foreach (var (op, count) in saved.Patches) edit.Patches[op].Truncate(count);
        }
        _appended.RemoveRange(mark.Appended, _appended.Count - mark.Appended);
        DeleteObjects(mark.Objects);
    }

    /// <summary>Takes back everything the batch added to the document, for an edit that is given up.</summary>
    public void Discard() => DeleteObjects(_firstObject);

    // Fonts and pictures are made in the document as soon as an edit asks for them; an edit taken back must not leave them to be saved.
    private void DeleteObjects(int from)
    {
        for (int number = from; number < document.NextObjectNumber; number++) document.Delete(number);
    }

    /// <summary>Whether a resource called <paramref name="name"/> is still waiting to be written to the stream of <paramref name="place"/>.</summary>
    public bool HasResource(Place place, string name) =>
        _edits.TryGetValue(place.Unit, out var edit) && edit.Resources.Any(r => r.Name == name);

    private UnitEdit? Edit(Place place)
    {
        if (!_edits.TryGetValue(place.Unit, out var edit))
        {
            edit = new UnitEdit(place.Unit, place.Visit);
            _edits[place.Unit] = edit;
        }
        else if (place.Unit.Visits > 1 && !ReferenceEquals(edit.Visit, place.Visit)) return null;
        return edit;
    }

    /// <summary>The patch for the text-showing operation <paramref name="op"/>; null when the same form is being edited from another place.</summary>
    public ShowPatch? Patch(Place place, int op)
    {
        if (Edit(place) is not { } edit) return null;
        if (!edit.Patches.TryGetValue(op, out var patch)) edit.Patches[op] = patch = new ShowPatch(place.Unit.Operations[op]);
        return patch;
    }

    public bool Replace(Place place, int start, int end, byte[] bytes)
    {
        if (Edit(place) is not { } edit) return false;
        edit.Splices.Add(new Splice(start, end, bytes));
        return true;
    }

    public bool Replace(Place place, int start, int end, string text) => Replace(place, start, end, Encoding.Latin1.GetBytes(text));

    public bool Insert(Place place, int at, byte[] bytes) => Replace(place, at, at, bytes);

    /// <summary>Replaces the operation <paramref name="op"/> with <paramref name="text"/> (nothing deletes it).</summary>
    public bool ReplaceOperation(Place place, int op, string text)
    {
        var o = place.Unit.Operations[op];
        return Replace(place, o.Start, o.End, text);
    }

    /// <summary>Registers a resource under a name not used anywhere on the page and returns it; null when the stream cannot be edited.</summary>
    public string? AddResource(Place place, string category, PdfObject value)
    {
        if (Edit(place) is not { } edit) return null;
        string name = NewName();
        edit.Resources.Add(new Resource(category, name, () => value));
        return name;
    }

    public void Append(byte[] content, params (string Category, string Name, PdfObject Value)[] resources)
    {
        _appended.Add(content);
        var edit = Edit(new Place(scan.PageUnit, null))!;
        foreach (var (category, name, value) in resources) edit.Resources.Add(new Resource(category, name, () => value));
    }

    /// <summary>A name for a resource of appended content, free on the page.</summary>
    public string NewName()
    {
        _names ??= UsedNames();
        for (int n = 1; ; n++)
        {
            string name = "LzE" + n;
            if (_names.Add(name)) return name;
        }
    }

    private HashSet<string> UsedNames()
    {
        var names = new HashSet<string>();
        void Collect(PdfDictionary? resources)
        {
            if (resources is null) return;
            foreach (var (_, value) in resources.Entries)
            {
                if (document.Resolve(value) is PdfDictionary category)
                {
                    foreach (var entry in category.Entries) names.Add(entry.Key);
                }
            }
        }
        Collect(page.Resources);
        foreach (var form in scan.Forms.Keys) Collect(document.Dict(form.Dictionary, "Resources"));
        return names;
    }

    /// <summary>Writes the changes to the document. Conflicts are found first and thrown before any object is touched.</summary>
    public void Apply()
    {
        var work = new List<Work>();
        var done = new HashSet<UnitEdit>();
        while (_edits.Values.Where(e => !done.Contains(e)).OrderByDescending(e => e.Depth).FirstOrDefault() is { } edit)
        {
            done.Add(edit);
            var splices = Compile(edit);
            byte[] data = Splices.Apply(edit.Unit.Data, splices);
            bool copy = edit.Visit is { } shared && IsShared(shared);
            if (copy)
            {
                var visit = edit.Visit!;
                var parent = Edit(new Place(visit.ParentUnit, visit.Parent))
                    ?? throw new EditConflictException("The form is painted from two places.");
                string name = NewName();
                var doOp = visit.ParentUnit.Operations[visit.DoOperation];
                parent.Splices.Add(new Splice(doOp.Start, doOp.End, Encoding.Latin1.GetBytes(new PdfName(name).ToString() + " Do")));
                var item = new Work(edit, data, true);
                parent.Resources.Add(new Resource("XObject", name, () => item.Reference!));
                work.Add(item);
            }
            else work.Add(new Work(edit, data, false));
        }

        // A form is rewritten in place, which Discard cannot take back, so the page is checked before any is written.
        foreach (var item in work.Where(w => w.Edit.Visit is null)) item.Plan = PlanPage(item.Edit);
        foreach (var item in work)
        {
            if (item.Edit.Visit is { } visit) WriteForm(item, visit);
            else WritePage(item);
        }
    }

    private static List<Splice> Compile(UnitEdit edit)
    {
        var all = new List<Splice>(edit.Splices);
        foreach (var patch in edit.Patches.Values) all.Add(patch.Compile());
        var sorted = all.Select((s, i) => (s, i)).OrderBy(x => x.s.Start).ThenBy(x => x.s.End).ThenBy(x => x.i).Select(x => x.s).ToList();
        for (int i = 1; i < sorted.Count; i++)
        {
            if (sorted[i - 1].End > sorted[i].Start) throw new EditConflictException("Two changes touch the same operators.");
        }
        return sorted;
    }

    private void WriteForm(Work item, FormVisit visit)
    {
        PdfStream target;
        if (item.Copy)
        {
            target = new PdfStream(visit.Form.Dictionary.Copy(), item.Data);
            item.Reference = document.Add(target);
        }
        else target = visit.Form;
        SetData(target, item.Data);
        if (item.Edit.Resources.Count == 0) return;
        var enclosing = visit.Parent is null ? page.Resources : document.Dict(visit.Parent.Form.Dictionary, "Resources");
        var resources = document.Dict(target.Dictionary, "Resources");
        if (resources is null || item.Copy) resources = (resources ?? enclosing)?.Copy() ?? new PdfDictionary();
        target.Dictionary["Resources"] = resources;
        AddResources(resources, item.Edit.Resources, copy: true);
    }

    private void AddResources(PdfDictionary resources, List<Resource> entries, bool copy)
    {
        foreach (var entry in entries)
        {
            var category = document.Dict(resources, entry.Category);
            if (category is null || copy) category = category?.Copy() ?? new PdfDictionary();
            category[entry.Name] = entry.Value();
            resources[entry.Category] = category;
        }
    }

    private static void SetData(PdfStream stream, byte[] decoded)
    {
        stream.Dictionary["Filter"] = new PdfName("FlateDecode");
        stream.Dictionary.Remove("DecodeParms");
        stream.Dictionary.Remove("DP");
        stream.Dictionary.Remove("F");
        stream.Data = PdfFilterEncoders.Flate(decoded);
    }

    private PdfStream NewStream(PdfDictionary? like, byte[] decoded)
    {
        var stream = new PdfStream(like?.Copy() ?? new PdfDictionary(), []);
        stream.Dictionary.Remove("Length");
        SetData(stream, decoded);
        return stream;
    }

    private PagePlan PlanPage(UnitEdit edit)
    {
        var parts = ReadParts();
        var splices = Compile(edit);
        // Groups of neighbouring parts, merged when a change spans the break between them.
        var groups = new List<(int Lo, int Hi)>();
        foreach (var s in splices)
        {
            int a = PartAt(parts, s.Start), b = PartAt(parts, s.End);
            if (a < 0 || b < 0) throw new EditConflictException("A change lies outside the page content.");
            var merged = (Lo: a, Hi: b);
            groups.RemoveAll(g =>
            {
                bool touches = g.Lo <= merged.Hi && merged.Lo <= g.Hi;
                if (touches) merged = (Math.Min(g.Lo, merged.Lo), Math.Max(g.Hi, merged.Hi));
                return touches;
            });
            groups.Add(merged);
        }
        int length = scan.PageUnit.Data.Length;
        foreach (var (lo, hi) in groups)
        {
            if (parts[lo].Start < 0 || parts[hi].End > length || parts[lo].Start > parts[hi].End) throw new EditConflictException("A change lies outside the page content.");
        }
        return new PagePlan(parts, splices, groups);
    }

    private void WritePage(Work item)
    {
        var edit = item.Edit;
        var (parts, splices, groups) = item.Plan!;
        var items = ContentItems();
        var replaced = new Dictionary<int, (int Hi, PdfObject Ref)>();
        var data = scan.PageUnit.Data;
        foreach (var (lo, hi) in groups.OrderBy(g => g.Lo))
        {
            int from = parts[lo].Start, to = parts[hi].End;
            var inside = splices.Where(s => s.Start >= from && s.End <= to).Select(s => new Splice(s.Start - from, s.End - from, s.Bytes)).ToList();
            byte[] bytes = Splices.Apply(data.AsSpan(from, to - from).ToArray(), inside);
            replaced[parts[lo].Item] = (parts[hi].Item, document.Add(NewStream(parts[lo].Stream.Dictionary, bytes)));
        }

        var list = new List<PdfObject>();
        for (int i = 0; i < items.Count; i++)
        {
            if (replaced.TryGetValue(i, out var r))
            {
                list.Add(r.Ref);
                i = r.Hi;
            }
            else list.Add(items[i]);
        }
        if (_appended.Count > 0)
        {
            var all = new MemoryStream();
            all.Write(Prefix(edit));
            foreach (var bytes in _appended) all.Write(bytes);
            list.Add(document.Add(NewStream(null, all.ToArray())));
        }
        if (_appended.Count > 0 && Wraps) list.Insert(0, document.Add(NewStream(null, "q\n"u8.ToArray())));
        if (list.Count > 0) page.Dictionary["Contents"] = list.Count == 1 && items.Count <= 1 ? list[0] : new PdfArray(list);
        if (edit.Resources.Count > 0) AddResources(ContentResources.ForEdit(document, page), edit.Resources, copy: false);
    }

    // A page that leaves state at its top level (a text mode, a clip, a dash) runs inside a q of its own, written
    // first and closed in Prefix, so none of it reaches the added content (8.4.2). A stray Q would pop that q
    // and change the page itself, and a page that leaves nothing needs none: it keeps the added content at the
    // level of the page's own, where Order can pass it.
    private bool Wraps => scan.PageUnit.States is { Stray: false, SetsTopLevel: true };

    private byte[] Prefix(UnitEdit edit)
    {
        var states = scan.PageUnit.States;
        var w = new ContentWriter();
        if (states.End.InText) w.Op("ET");
        for (int i = Wraps ? 0 : 1; i <= states.End.Depth; i++) w.Restore();
        if (!Wraps && states.BaseCtm.Invert() is { } inverse && states.BaseCtm != PdfMatrix.Identity) w.Concat(inverse);
        if (states.Stray && states.SetsTopLevel) Reset(w, edit, states.End);
        return w.ToArray();
    }

    // With a stray Q there is no q of ours to close, so the state the page left is put back to its initial values
    // (Tables 52, 53 and 57). A clip it left cannot be undone.
    private void Reset(ContentWriter w, UnitEdit edit, OpState end)
    {
        w.TextRenderMode(0).CharSpacing(0).WordSpacing(0).Op("Tz", 100).Op("Ts", 0).Raw("[] 0 d");
        w.LineWidth(1).Op("J", 0).Op("j", 0).Op("M", 10);
        if (end.States.Count == 0) return;
        var initial = new PdfDictionary();
        initial["Type"] = new PdfName("ExtGState");
        initial["CA"] = new PdfNumber(1L);
        initial["ca"] = new PdfNumber(1L);
        initial["BM"] = new PdfName("Normal");
        initial["SMask"] = new PdfName("None");
        string name = NewName();
        edit.Resources.Add(new Resource("ExtGState", name, () => initial));
        w.GraphicsState(name);
    }

    private sealed record Part(int Item, PdfStream Stream, int Start, int End);

    private List<PdfObject> ContentItems()
    {
        var contents = document.Resolve(page.Dictionary["Contents"]);
        return contents switch
        {
            PdfArray array => [.. array.Items],
            PdfStream => [page.Dictionary["Contents"]!],
            _ => [],
        };
    }

    // The streams as PdfPage.Contents joins them: decoded, a newline between, unreadable ones left out.
    private List<Part> ReadParts()
    {
        var parts = new List<Part>();
        var items = ContentItems();
        int at = 0;
        long room = 256L << 20;
        for (int i = 0; i < items.Count; i++)
        {
            if (document.Resolve(items[i]) is not PdfStream stream) continue;
            int length;
            try
            {
                length = document.Data(stream, room).Length;
            }
            catch (PdfReadException)
            {
                continue;
            }
            room = Math.Max(0, room - length - 1);
            if (parts.Count > 0) at++;
            parts.Add(new Part(i, stream, at, at + length));
            at += length;
        }
        return parts;
    }

    private static int PartAt(List<Part> parts, int position)
    {
        for (int i = 0; i < parts.Count; i++)
        {
            if (position >= parts[i].Start && position <= parts[i].End) return i;
        }
        return -1;
    }

    // A form inside a copied form is reached by the copy too, so it is shared whenever an enclosing one is.
    private bool IsShared(FormVisit visit)
    {
        if (visit.Unit.Visits > 1 || (visit.Parent is { } parent && IsShared(parent))) return true;
        var references = _references ??= CountReferences();
        if (references.GetValueOrDefault(visit.Form.Number) > 1) return true;
        var owner = visit.Parent is null ? page.Dictionary : visit.Parent.Form.Dictionary;
        var raw = owner["Resources"];
        if (raw is null) return true;
        if (raw is PdfReference r && references.GetValueOrDefault(r.Number) > 1) return true;
        return document.Dict(owner, "Resources")?["XObject"] is PdfReference x && references.GetValueOrDefault(x.Number) > 1;
    }

    private Dictionary<int, int> CountReferences()
    {
        var counts = new Dictionary<int, int>();
        var stack = new Stack<PdfObject>();
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) is not { } root) continue;
            stack.Push(root);
            while (stack.Count > 0)
            {
                switch (stack.Pop())
                {
                    case PdfReference r: counts[r.Number] = counts.GetValueOrDefault(r.Number) + 1; break;
                    case PdfDictionary d: foreach (var entry in d.Entries) stack.Push(entry.Value); break;
                    case PdfArray a: foreach (var item in a.Items) stack.Push(item); break;
                    case PdfStream s: stack.Push(s.Dictionary); break;
                }
            }
        }
        return counts;
    }
}

internal static class Splices
{
    /// <summary>The data with sorted, non-overlapping splices applied.</summary>
    public static byte[] Apply(byte[] data, IReadOnlyList<Splice> splices)
    {
        if (splices.Count == 0) return data;
        var output = new MemoryStream(data.Length + 64);
        int at = 0;
        foreach (var s in splices)
        {
            output.Write(data, at, s.Start - at);
            if (s.Bytes.Length > 0)
            {
                // Inserted operators must not run into the token on either side of them (7.2.3).
                if (output.Length > 0 && IsRegular(output.GetBuffer()[output.Length - 1]) && IsRegular(s.Bytes[0])) output.WriteByte((byte)' ');
                output.Write(s.Bytes);
                if (s.End < data.Length && IsRegular(s.Bytes[^1]) && IsRegular(data[s.End])) output.WriteByte((byte)' ');
            }
            at = s.End;
        }
        output.Write(data, at, data.Length - at);
        return output.ToArray();
    }

    private static bool IsRegular(byte b) => b > 32 && b < 127 && "()<>[]{}/%"u8.IndexOf(b) < 0;
}
