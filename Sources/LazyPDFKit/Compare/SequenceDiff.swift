import Foundation

// Twin of windows/LazyPDF.Core/Compare/SequenceDiff.cs: shortest edit script of two int sequences (Myers, "An O(ND)
// difference algorithm", 1986).

enum SequenceDiff {
    /// The old items `[oldStart, oldStart + oldCount)` became the new items `[newStart, newStart + newCount)`.
    struct Hunk: Equatable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int

        init(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
        }
    }

    /// The places where the sequences differ. Past `maxEdits` edits in the part between the common ends the search stops
    /// and that part is one hunk, which bounds the memory at about maxEdits squared ints.
    static func diff(_ a: [Int], _ b: [Int], _ maxEdits: Int = 2000) -> [Hunk] {
        var head = 0
        while head < a.count && head < b.count && a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head && tail < b.count - head && a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        let middleA = Array(a[head..<(a.count - tail)])
        let middleB = Array(b[head..<(b.count - tail)])
        var hunks: [Hunk] = []
        if middleA.isEmpty && middleB.isEmpty { return hunks }
        if middleA.isEmpty || middleB.isEmpty || !tryMyers(middleA, middleB, maxEdits, &hunks) {
            hunks = [Hunk(0, middleA.count, 0, middleB.count)]
        }
        for i in 0..<hunks.count {
            hunks[i].oldStart += head
            hunks[i].newStart += head
        }
        return hunks
    }

    private static func tryMyers(_ a: [Int], _ b: [Int], _ maxEdits: Int, _ hunks: inout [Hunk]) -> Bool {
        let n = a.count, m = b.count
        let max = min(n + m, maxEdits)
        if max < 0 { return false }
        let offset = max + 1
        var v = [Int](repeating: 0, count: 2 * max + 3)
        var trace: [[Int]] = []
        var found = -1
        var d = 0
        while d <= max && found < 0 {
            var k = -d
            while k <= d {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    found = d
                    break
                }
                k += 2
            }
            trace.append(Array(v[(offset - d)..<(offset + d + 1)]))
            d += 1
        }
        if found < 0 { return false }

        var edits: [(x: Int, y: Int, delete: Bool)] = []
        var px = n, py = m
        var back = found
        while back > 0 {
            let previous = trace[back - 1]
            let k = px - py
            let step = back
            func at(_ diagonal: Int) -> Int { previous[diagonal + step - 1] }
            let previousK = k == -step || (k != step && at(k - 1) < at(k + 1)) ? k + 1 : k - 1
            let x = at(previousK), y = x - previousK
            edits.append((x: x, y: y, delete: previousK != k + 1))
            (px, py) = (x, y)
            back -= 1
        }
        edits.reverse()

        var endX = -1, endY = -1
        var current = Hunk(0, 0, 0, 0)
        for (x, y, delete) in edits {
            if x != endX || y != endY {
                if endX >= 0 { hunks.append(current) }
                current = Hunk(x, 0, y, 0)
            }
            if delete {
                current.oldCount += 1
                (endX, endY) = (x + 1, y)
            } else {
                current.newCount += 1
                (endX, endY) = (x, y + 1)
            }
        }
        if endX >= 0 { hunks.append(current) }
        return true
    }
}
