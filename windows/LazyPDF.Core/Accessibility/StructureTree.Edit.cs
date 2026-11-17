namespace LazyPDF.Core;

public sealed partial class StructureTree
{
    /// <summary>
    /// Gives <paramref name="element"/> a new type. A standard type is written as is; any other needs a role map
    /// entry, which is kept when there is one and otherwise added, taking <paramref name="mapsTo"/> or else the
    /// standard type the element has now. False when the type is empty or does not lead to a standard type.
    /// Where the element may go is for <see cref="TagRules.CanSetType"/> to say; nothing is checked here.
    /// </summary>
    public bool SetType(StructElement element, string type, string? mapsTo = null)
    {
        if (ResolveNew(element, type, mapsTo) is null) return false;
        if (!IsStandard(type) && !RoleMap.ContainsKey(type)) RoleMap[type] = mapsTo ?? StandardType(element.Type);
        element.Type = type;
        return true;
    }

    internal string? ResolveNew(StructElement element, string type, string? mapsTo)
    {
        if (type.Length == 0) return null;
        if (IsStandard(type)) return type;
        string resolved = StandardType(RoleMap.ContainsKey(type) ? type : mapsTo ?? element.Type);
        return IsStandard(resolved) ? resolved : null;
    }

    /// <summary>Swaps <paramref name="kid"/> with the kid before it. False at the first place or when it is not in the tree.</summary>
    public bool MoveUp(StructKid kid) => Shift(kid, -1);

    /// <summary>Swaps <paramref name="kid"/> with the kid after it. False at the last place or when it is not in the tree.</summary>
    public bool MoveDown(StructKid kid) => Shift(kid, 1);

    private bool Shift(StructKid kid, int step)
    {
        if (kid.Parent is { } parent)
        {
            int at = parent.KidList.IndexOf(kid);
            if (at < 0 || at + step < 0 || at + step >= parent.KidList.Count) return false;
            parent.KidList.RemoveAt(at);
            parent.KidList.Insert(at + step, kid);
            return true;
        }
        if (kid is not StructElement element) return false;
        int root = _roots.IndexOf(element);
        if (root < 0 || root + step < 0 || root + step >= _roots.Count) return false;
        _roots.RemoveAt(root);
        _roots.Insert(root + step, element);
        return true;
    }

    /// <summary>Makes <paramref name="element"/> the last kid of the element before it. False when that kid is not an element or the element is not in the tree.</summary>
    public bool Indent(StructElement element)
    {
        int at = IndexIn(element);
        if (at < 1) return false;
        StructKid before = element.Parent is { } parent ? parent.KidList[at - 1] : _roots[at - 1];
        if (before is not StructElement previous) return false;
        Move(element, previous, -1);
        return true;
    }

    /// <summary>Puts <paramref name="element"/> right after its parent, in the parent's parent. False at the top.</summary>
    public bool Outdent(StructElement element)
    {
        if (element.Parent is not { } parent || IndexIn(element) < 0) return false;
        int after = IndexIn(parent);
        if (after < 0) return false;
        Move(element, parent.Parent, after + 1);
        return true;
    }

    /// <summary>
    /// Takes <paramref name="element"/> out and keeps what it held: its kids, marked content and objects included,
    /// go into its parent at its place. False when it is not in the tree, or is a root with content or objects,
    /// which the root cannot hold.
    /// </summary>
    public bool Unwrap(StructElement element)
    {
        int at = IndexIn(element);
        if (at < 0) return false;
        if (element.Parent is null && element.KidList.Any(k => k is not StructElement)) return false;
        var kids = element.KidList.ToList();
        var parent = element.Parent;
        Detach(element);
        element.KidList.Clear();
        foreach (var kid in kids) kid.Parent = null;
        for (int i = 0; i < kids.Count; i++) Insert(parent, kids[i], at + i);
        if (element.Reference is { } reference) _removed.Add(reference.Number);
        return true;
    }

    private int IndexIn(StructKid kid) =>
        kid.Parent is { } parent ? parent.KidList.IndexOf(kid) : kid is StructElement element ? _roots.IndexOf(element) : -1;
}
