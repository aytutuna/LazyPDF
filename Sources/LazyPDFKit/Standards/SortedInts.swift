import Foundation

// No twin. What SortedSet<int> is to the checker and the converter: a set that lists its members in order. The checker
// adds to the set of a font while it walks the content, so it is a class, as the C# collection is a reference.

final class SortedInts: Sequence {
    private var members = Set<Int>()
    private var ordered: [Int]?

    init() {}

    init<S: Sequence>(_ values: S) where S.Element == Int {
        members = Set(values)
    }

    var count: Int { members.count }

    func contains(_ value: Int) -> Bool { members.contains(value) }

    /// False when the value was there already.
    @discardableResult
    func insert(_ value: Int) -> Bool {
        let added = members.insert(value).inserted
        if added { ordered = nil }
        return added
    }

    var sorted: [Int] {
        if let ordered { return ordered }
        let list = members.sorted()
        ordered = list
        return list
    }

    func makeIterator() -> IndexingIterator<[Int]> { sorted.makeIterator() }
}
