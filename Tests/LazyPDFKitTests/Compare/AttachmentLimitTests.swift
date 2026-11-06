import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/AttachmentLimitTests.cs: the same cases. The random bytes come from a port of
// System.Random(seed). The time limits are six times the C# ones: a debug build of Swift is slower than .NET's.

final class AttachmentLimitTests: CompareTestCase {
    private let mib = 1 << 20

    private func with(_ files: [(name: String, data: [UInt8])]) throws -> PdfDocument {
        let document = try doc([page("files")])
        for (name, data) in files { try PdfAttachments.add(document, name, data) }
        return try open(document.saveRewrite())
    }

    func test_fileOverTheSizeCapIsJudgedByItsStoredBytes() throws {
        let big = [UInt8](repeating: 0, count: 65 * mib)
        var other = big
        other[other.count - 1] = 1
        let before = try with([("big.bin", big)])
        let same = try with([("big.bin", big)])
        let after = try with([("big.bin", other)])
        XCTAssertTrue(try PdfComparer.compare(before, same).isIdentical)
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertTrue(change.oldText.contains("bytes stored"))
    }

    func test_storedBytesPastTheBudgetAreLeftUnreadAndTheFileIsJudgedByItsContent() throws {
        let big = [UInt8](repeating: 0, count: 257 * mib)
        var documents: [PdfDocument] = []
        for text in ["hello", "hello", "howdy"] {
            let document = try doc([page("files")])
            try PdfAttachments.add(document, "big.bin", big)
            try PdfAttachments.add(document, "small.txt", Array(text.utf8))
            documents.append(document)
        }
        XCTAssertTrue(try PdfComparer.compare(documents[0], documents[1]).isIdentical)
        let change = try single(try PdfComparer.compare(documents[0], documents[2]).changes)
        XCTAssertTrue(try XCTUnwrap(change.detail).contains("small.txt"))
    }

    func test_unfilteredFilesOverTheCapDoNotUseUpTheBudget() throws {
        var generator = DotNetRandom(7)
        let random = generator.nextBytes(65 * mib)
        let text = Array(String(repeating: "some text ", count: 100).utf8)
        let file = try with([("a1.bin", random), ("a2.bin", random), ("a3.bin", random), ("a4.bin", random), ("b.txt", text)])
        XCTAssertTrue(try PdfComparer.compare(file, file).isIdentical)
    }

    func test_fileLaterInTheListIsNotChangedByAnEarlierOneBeingRemoved() throws {
        let zeros = [UInt8](repeating: 0, count: 60 * mib)
        let names = ["a.bin", "b.bin", "c.bin", "d.bin", "e.bin"]
        let before = try with(names.map { ($0, zeros) })
        let after = try with(names.dropFirst().map { ($0, zeros) })
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertTrue(try XCTUnwrap(change.detail).contains("a.bin"))
    }

    // Four files that do not decode, each charged the whole cap, then a file whose two sides are packed differently.
    private func withUndecodable(_ word: String, _ level: CompressionLevel) throws -> PdfDocument {
        let document = try doc([page("files")])
        for name in ["u1.bin", "u2.bin", "u3.bin", "u4.bin"] {
            let added = try PdfAttachments.add(document, name, Array("\(word) \(name)".utf8))
            try XCTUnwrap(PdfAttachments.streamOf(document, added)).dictionary["Filter"] = PdfName("NoSuchDecode")
        }
        let text = Array(String(repeating: "some words to pack ", count: 200).utf8)
        let last = try PdfAttachments.add(document, "z.txt", text)
        try XCTUnwrap(PdfAttachments.streamOf(document, last)).data = PdfFilterEncoders.flate(text, level)
        return try open(document.saveRewrite())
    }

    func test_failedDecodesUseUpTheBudget() throws {
        let before = try withUndecodable("one", .optimal)
        let after = try withUndecodable("uno", .noCompression)
        let result = try PdfComparer.compare(before, after)
        let change = try single(result.changes, where: { $0.detail?.contains("z.txt") == true })
        XCTAssertTrue(change.oldText.contains("bytes stored"))
    }

    func test_filesStoredAlikeCostNoBudget() throws {
        let before = try withUndecodable("one", .optimal)
        let after = try withUndecodable("one", .noCompression)
        XCTAssertTrue(try PdfComparer.compare(before, before).isIdentical)
        XCTAssertFalse(try PdfComparer.compare(before, after).changes.contains { $0.detail?.contains("z.txt") == true })
    }

    func test_cancelledTokenStopsTheDocumentComparison() async throws {
        let before = try with([("a.txt", [1, 2, 3])])
        let after = try with([("a.txt", [1, 2, 4])])
        let task = Task { () throws -> Void in
            while !Task.isCancelled { await Task.yield() }
            var changes: [CompareChange] = []
            try Comparison(before, after, CompareOptions()).compareDocuments([], &changes)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    private func sharedBy(_ entries: Int) throws -> PdfDocument {
        let document = try doc([page("files")])
        let added = try PdfAttachments.add(document, "r.pdf", [1, 2, 3])
        let tree = try XCTUnwrap(document.dict(document.dict(document.catalog, "Names"), "EmbeddedFiles"))
        let spec = try XCTUnwrap(added.spec)
        var items: [PdfObject] = []
        for i in 0..<entries {
            items.append(PdfText.toObject(String(format: "k%06ld", i)))
            items.append(spec)
        }
        tree["Names"] = PdfArray(items)
        return try open(document.saveRewrite())
    }

    func test_manyEntriesWithOneFileNameAreNamedInLinearTime() throws {
        let file = try sharedBy(20_000)
        let start = Date()
        XCTAssertTrue(try PdfComparer.compare(file, file).isIdentical)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 60, "\(elapsed) s")
    }
}
