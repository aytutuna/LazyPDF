import Foundation

// Twin of windows/LazyPDF.Core/Compare/PageAligner.cs: pairs the pages of two files by what is on them. The pairs that
// keep their order and add up to the most similarity are found first (a weighted longest increasing subsequence), then the
// pages left over are paired as moved when they are alike, and what remains between two anchors is paired in order.

enum PageAligner {
    static let matchThreshold = 0.5
    private static let gapThreshold = 0.15
    private static let maxPostings = 64
    private static let topCandidates = 8
    private static let sameHashCandidates = 4
    private static let poorWeight = 0.01
    private static let maxGapCells = 40_000

    private struct Candidate {
        let old: Int
        let new: Int
        let similarity: Double
    }

    /// A page signature is the sorted distinct hashes of its word pairs (and pictures); a page with little text (a scan, a
    /// slide) is paired with whatever stands in its gap, since words cannot tell it apart.
    static func align(_ before: [[Int]], _ after: [[Int]], _ oldPoor: [Bool], _ newPoor: [Bool]) throws -> [PagePair] {
        let candidates = try Self.candidates(before, after, matchThreshold)
        let anchors = chain(candidates, after.count)
        var oldTo = [Int](repeating: -1, count: before.count)
        var newTo = [Int](repeating: -1, count: after.count)
        for c in anchors {
            oldTo[c.old] = c.new
            newTo[c.new] = c.old
        }
        var movedNew = Set<Int>()
        let loose = candidates.filter { oldTo[$0.old] < 0 && newTo[$0.new] < 0 }
        let ordered = loose.enumerated().sorted { a, b in
            if a.element.similarity != b.element.similarity { return a.element.similarity > b.element.similarity }
            let da = abs(a.element.old - a.element.new), db = abs(b.element.old - b.element.new)
            return da != db ? da < db : a.offset < b.offset
        }
        for (_, c) in ordered {
            if oldTo[c.old] >= 0 || newTo[c.new] >= 0 { continue }
            oldTo[c.old] = c.new
            newTo[c.new] = c.old
            movedNew.insert(c.new)
        }

        var result: [PagePair] = []
        var oi = 0, nj = 0
        let last = Candidate(old: before.count, new: after.count, similarity: 0)
        for anchor in anchors.sorted(by: { $0.old < $1.old }) + [last] {
            let freeOld = (oi..<max(oi, anchor.old)).filter { oldTo[$0] < 0 }
            let freeNew = (nj..<max(nj, anchor.new)).filter { newTo[$0] < 0 }
            let paired = try gap(freeOld, freeNew, before, after, oldPoor, newPoor)
            let used = Set(paired.values)
            for i in freeOld where !used.contains(i) { result.append(PagePair(i, -1, 0, false)) }
            for j in nj..<max(nj, anchor.new) {
                if let old = paired[j] {
                    result.append(PagePair(old, j, dice(before[old], after[j]), false))
                } else if newTo[j] >= 0 {
                    result.append(PagePair(newTo[j], j, dice(before[newTo[j]], after[j]), movedNew.contains(j)))
                } else {
                    result.append(PagePair(-1, j, 0, false))
                }
            }
            if anchor.old < before.count { result.append(PagePair(anchor.old, anchor.new, anchor.similarity, false)) }
            oi = anchor.old + 1
            nj = anchor.new + 1
        }
        return result
    }

    /// The pages left between two anchors, paired in order by the pairing of most similarity, so that one inserted page does
    /// not cancel the rest. Pages of equal weight pair with the earliest partner. A gap too big for the full table is split
    /// first at the pages that share enough words, wherever they stand.
    private static func gap(_ freeOld: [Int], _ freeNew: [Int], _ before: [[Int]], _ after: [[Int]],
                            _ oldPoor: [Bool], _ newPoor: [Bool]) throws -> [Int: Int] {
        var paired: [Int: Int] = [:]
        func weight(_ i: Int, _ j: Int) -> Double {
            let value = dice(before[i], after[j])
            if value >= gapThreshold { return value }
            return oldPoor[i] && newPoor[j] ? poorWeight : 0
        }

        func table(_ oldPages: [Int], _ newPages: [Int]) throws {
            let n = oldPages.count, m = newPages.count
            if n == 0 || m == 0 { return }
            let width = m + 1
            var best = [Double](repeating: 0, count: (n + 1) * width)
            for a in stride(from: n - 1, through: 0, by: -1) {
                try Task.checkCancellation()
                for b in stride(from: m - 1, through: 0, by: -1) {
                    best[a * width + b] = max(best[(a + 1) * width + b], max(best[a * width + b + 1], best[(a + 1) * width + b + 1] + weight(oldPages[a], newPages[b])))
                }
            }
            var a = 0, b = 0
            while a < n && b < m {
                let w = weight(oldPages[a], newPages[b])
                if w > 0 && best[a * width + b] == best[(a + 1) * width + b + 1] + w {
                    paired[newPages[b]] = oldPages[a]
                    a += 1
                    b += 1
                } else if best[a * width + b] == best[(a + 1) * width + b] {
                    a += 1
                } else {
                    b += 1
                }
            }
        }

        // What the chain left between its pairs has no page alike on both sides. Pages with no words to tell them apart
        // (scans) pair by position when the counts agree.
        func rest(_ oldPages: [Int], _ newPages: [Int]) throws {
            if oldPages.count * newPages.count <= maxGapCells {
                try table(oldPages, newPages)
            } else if oldPages.count == newPages.count {
                for a in 0..<oldPages.count where weight(oldPages[a], newPages[a]) > 0 { paired[newPages[a]] = oldPages[a] }
            }
        }

        if freeOld.count * freeNew.count <= maxGapCells {
            try table(freeOld, freeNew)
            return paired
        }
        let found = try candidates(freeOld.map { before[$0] }, freeNew.map { after[$0] }, gapThreshold)
        var a0 = 0, b0 = 0
        for c in chain(found, freeNew.count) {
            try rest(Array(freeOld[a0..<c.old]), Array(freeNew[b0..<c.new]))
            paired[freeNew[c.new]] = freeOld[c.old]
            a0 = c.old + 1
            b0 = c.new + 1
        }
        try rest(Array(freeOld[a0...]), Array(freeNew[b0...]))
        return paired
    }

    private static func candidates(_ before: [[Int]], _ after: [[Int]], _ threshold: Double) throws -> [Candidate] {
        var index: [Int: [Int]] = [:]
        var byHash: [Int: [Int]] = [:]
        for i in 0..<before.count {
            for s in before[i] { index[s, default: []].append(i) }
            byHash[hash(before[i]), default: []].append(i)
        }

        var result: [Candidate] = []
        for j in 0..<after.count {
            try Task.checkCancellation()
            var chosen: [Int] = []
            var seen = Set<Int>()
            func choose(_ i: Int) {
                if seen.insert(i).inserted { chosen.append(i) }
            }
            var overlap: [Int: Int] = [:]
            var arrival: [Int] = []
            for s in after[j] {
                guard let list = index[s], list.count <= maxPostings else { continue }
                for i in list {
                    if overlap[i] == nil { arrival.append(i) }
                    overlap[i, default: 0] += 1
                }
            }
            // Ties keep the order the pages were first met in, as the C# stable sort does.
            let ranked = arrival.enumerated().sorted { a, b in
                let ca = overlap[a.element] ?? 0, cb = overlap[b.element] ?? 0
                if ca != cb { return ca > cb }
                let da = abs(a.element - j), db = abs(b.element - j)
                return da != db ? da < db : a.offset < b.offset
            }
            for (_, i) in ranked.prefix(topCandidates) { choose(i) }
            if let identical = byHash[hash(after[j])] {
                let closest = identical.enumerated().sorted { a, b in
                    let da = abs(a.element - j), db = abs(b.element - j)
                    return da != db ? da < db : a.offset < b.offset
                }
                for (_, i) in closest.prefix(sameHashCandidates) { choose(i) }
            }
            var near = max(0, j - 1)
            while near <= min(before.count - 1, j + 1) {
                choose(near)
                near += 1
            }
            for i in chosen {
                let similarity = dice(before[i], after[j])
                if similarity >= threshold { result.append(Candidate(old: i, new: j, similarity: similarity)) }
            }
        }
        return result
    }

    /// The order-keeping subset with the largest total similarity: for each old page in turn, the best chain ending left of
    /// its partner.
    private static func chain(_ candidates: [Candidate], _ newCount: Int) -> [Candidate] {
        let sorted = candidates.sorted { $0.old != $1.old ? $0.old < $1.old : $0.new < $1.new }
        var best = [Double](repeating: 0, count: sorted.count)
        var previous = [Int](repeating: 0, count: sorted.count)
        var tree = [(weight: Double, item: Int)](repeating: (0.0, -1), count: newCount + 2)
        var winner = -1
        var start = 0
        while start < sorted.count {
            var end = start
            while end < sorted.count && sorted[end].old == sorted[start].old { end += 1 }
            for k in start..<end {
                let (weight, item) = query(tree, sorted[k].new)
                best[k] = weight + sorted[k].similarity
                previous[k] = item
                if winner < 0 || best[k] > best[winner] { winner = k }
            }
            for k in start..<end { update(&tree, sorted[k].new + 1, best[k], k) }
            start = end
        }
        var result: [Candidate] = []
        var k = winner
        while k >= 0 {
            result.append(sorted[k])
            k = previous[k]
        }
        result.reverse()
        return result
    }

    /// The best entry among new pages below `newIndex`.
    private static func query(_ tree: [(weight: Double, item: Int)], _ newIndex: Int) -> (Double, Int) {
        var best = (0.0, -1)
        var p = newIndex
        while p > 0 {
            if tree[p].weight > best.0 { best = (tree[p].weight, tree[p].item) }
            p -= p & -p
        }
        return best
    }

    private static func update(_ tree: inout [(weight: Double, item: Int)], _ position: Int, _ weight: Double, _ item: Int) {
        var p = position
        while p < tree.count {
            if weight > tree[p].weight { tree[p] = (weight, item) }
            p += p & -p
        }
    }

    static func dice(_ a: [Int], _ b: [Int]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var i = 0, j = 0, common = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                common += 1
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return 2.0 * Double(common) / Double(a.count + b.count)
    }

    private static func hash(_ signature: [Int]) -> Int {
        var h = 17 &+ signature.count
        for s in signature { h = h &* 1_000_003 &+ s }
        return h
    }
}
