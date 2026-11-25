import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureTree.Edit.cs: edits of one element and of its place in the tree.
// `indent` and `outdent` throw the `ArgumentException` of `move`, which the C# calls through.

extension StructureTree {
    /// Gives `element` a new type. A standard type is written as is; any other needs a role map entry, which is kept when
    /// there is one and otherwise added, taking `mapsTo` or else the standard type the element has now. False when the type
    /// is empty or does not lead to a standard type. Where the element may go is for `TagRules.canSetType` to say; nothing
    /// is checked here.
    @discardableResult
    public func setType(_ element: StructElement, _ type: String, _ mapsTo: String? = nil) -> Bool {
        if resolveNew(element, type, mapsTo) == nil { return false }
        if !Self.isStandard(type) && !roleMap.containsKey(type) { roleMap[type] = mapsTo ?? standardType(element.type) }
        element.type = type
        return true
    }

    func resolveNew(_ element: StructElement, _ type: String, _ mapsTo: String?) -> String? {
        if type.isEmpty { return nil }
        if Self.isStandard(type) { return type }
        let resolved = standardType(roleMap.containsKey(type) ? type : (mapsTo ?? element.type))
        return Self.isStandard(resolved) ? resolved : nil
    }

    /// Swaps `kid` with the kid before it. False at the first place or when it is not in the tree.
    @discardableResult
    public func moveUp(_ kid: StructKid) -> Bool { shift(kid, -1) }

    /// Swaps `kid` with the kid after it. False at the last place or when it is not in the tree.
    @discardableResult
    public func moveDown(_ kid: StructKid) -> Bool { shift(kid, 1) }

    private func shift(_ kid: StructKid, _ step: Int) -> Bool {
        if let parent = kid.parent {
            guard let at = parent.kidList.firstIndex(where: { $0 === kid }), at + step >= 0, at + step < parent.kidList.count else { return false }
            parent.kidList.remove(at: at)
            parent.kidList.insert(kid, at: at + step)
            return true
        }
        guard let element = kid as? StructElement, let root = rootList.firstIndex(where: { $0 === element }),
              root + step >= 0, root + step < rootList.count else { return false }
        rootList.remove(at: root)
        rootList.insert(element, at: root + step)
        return true
    }

    /// Makes `element` the last kid of the element before it. False when that kid is not an element or the element is not in the tree.
    @discardableResult
    public func indent(_ element: StructElement) throws -> Bool {
        let at = indexIn(element)
        if at < 1 { return false }
        let before: StructKid = element.parent.map { $0.kidList[at - 1] } ?? rootList[at - 1]
        guard let previous = before as? StructElement else { return false }
        try move(element, previous, -1)
        return true
    }

    /// Puts `element` right after its parent, in the grandparent. False at the top.
    @discardableResult
    public func outdent(_ element: StructElement) throws -> Bool {
        guard let parent = element.parent, indexIn(element) >= 0 else { return false }
        let after = indexIn(parent)
        if after < 0 { return false }
        try move(element, parent.parent, after + 1)
        return true
    }

    /// Takes `element` out and keeps what it held: its kids, marked content and objects included, go into its parent at its
    /// place. False when it is not in the tree, or is a root with content or objects, which the root cannot hold.
    @discardableResult
    public func unwrap(_ element: StructElement) -> Bool {
        let at = indexIn(element)
        if at < 0 { return false }
        if element.parent == nil && element.kidList.contains(where: { !($0 is StructElement) }) { return false }
        let kids = element.kidList
        let parent = element.parent
        detach(element)
        element.kidList.removeAll()
        for kid in kids { kid.parent = nil }
        for (i, kid) in kids.enumerated() { insert(parent, kid, at + i) }
        if let reference = element.reference { removed.insert(reference.number) }
        return true
    }

    func indexIn(_ kid: StructKid) -> Int {
        if let parent = kid.parent { return parent.kidList.firstIndex(where: { $0 === kid }) ?? -1 }
        if let element = kid as? StructElement { return rootList.firstIndex(where: { $0 === element }) ?? -1 }
        return -1
    }
}
