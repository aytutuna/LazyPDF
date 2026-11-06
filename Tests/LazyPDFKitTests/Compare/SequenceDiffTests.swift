import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/SequenceDiffTests.cs: the same cases. The random numbers come from a port of
// System.Random(seed), so the sequences are those of the C# test.

final class SequenceDiffTests: XCTestCase {
    private func apply(_ a: [Int], _ b: [Int], _ hunks: [SequenceDiff.Hunk]) -> [Int] {
        var result: [Int] = []
        var at = 0
        for h in hunks {
            result += a[at..<h.oldStart]
            result += b[h.newStart..<(h.newStart + h.newCount)]
            at = h.oldStart + h.oldCount
        }
        result += a[at...]
        return result
    }

    func test_equalSequencesHaveNoHunks() {
        XCTAssertTrue(SequenceDiff.diff([1, 2, 3], [1, 2, 3]).isEmpty)
    }

    func test_oneSideEmptyIsOneHunk() {
        XCTAssertEqual(SequenceDiff.diff([], [1, 2, 3]), [SequenceDiff.Hunk(0, 0, 0, 3)])
        XCTAssertEqual(SequenceDiff.diff([1, 2, 3], []), [SequenceDiff.Hunk(0, 3, 0, 0)])
    }

    func test_replacementInTheMiddleIsOneHunk() {
        XCTAssertEqual(SequenceDiff.diff([1, 2, 3, 4, 5], [1, 2, 8, 9, 4, 5]), [SequenceDiff.Hunk(2, 1, 2, 2)])
    }

    func test_separateEditsAreSeparateHunks() {
        let hunks = SequenceDiff.diff([1, 2, 3, 4, 5, 6, 7], [1, 9, 3, 4, 5, 7])
        XCTAssertEqual(hunks, [SequenceDiff.Hunk(1, 1, 1, 1), SequenceDiff.Hunk(5, 1, 5, 0)])
    }

    func test_hunksRebuildTheNewSequenceAndAreMinimal() {
        var random = DotNetRandom(7)
        for round in 0..<300 {
            let aLength = random.next(40)
            let a = (0..<aLength).map { _ in random.next(6) }
            let bLength = random.next(40)
            let b = (0..<bLength).map { _ in random.next(6) }
            let hunks = SequenceDiff.diff(a, b)
            XCTAssertEqual(apply(a, b, hunks), b, "round \(round)")
            let edits = hunks.reduce(0) { $0 + $1.oldCount + $1.newCount }
            XCTAssertEqual(edits, a.count + b.count - 2 * lcs(a, b), "round \(round)")
        }
    }

    func test_pastTheEditCapTheMiddleIsOneHunk() {
        let a = (0..<400).map { $0 * 2 }
        let b = (0..<400).map { $0 * 2 + 1 }
        XCTAssertEqual(SequenceDiff.diff(a, b, 50), [SequenceDiff.Hunk(0, 400, 0, 400)])
    }

    func test_commonEndsAreTrimmedBeforeTheCapApplies() {
        let a = Array(0..<5000) + [1_000_000] + Array(0..<5000)
        let b = Array(0..<5000) + [2_000_000] + Array(0..<5000)
        XCTAssertEqual(SequenceDiff.diff(a, b, 10), [SequenceDiff.Hunk(5000, 1, 5000, 1)])
    }

    private func lcs(_ a: [Int], _ b: [Int]) -> Int {
        var t = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                t[i][j] = a[i - 1] == b[j - 1] ? t[i - 1][j - 1] + 1 : max(t[i - 1][j], t[i][j - 1])
            }
        }
        return t[a.count][b.count]
    }
}
