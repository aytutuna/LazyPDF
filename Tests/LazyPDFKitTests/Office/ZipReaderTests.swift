import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/ZipReaderTests.cs: the same cases.

final class ZipReaderTests: XCTestCase {
    private struct Part {
        var name: String
        var packed: [UInt8]
        var size: Int
        var crc: UInt32
        var method = 8
        var flags = 0
    }

    private func raw(_ data: [UInt8]) -> [UInt8] {
        let packed = PdfFilterEncoders.flate(data, .optimal)
        return Array(packed[2..<(packed.count - 4)])
    }

    private func deflated(_ name: String, _ data: [UInt8]) -> Part {
        Part(name: name, packed: raw(data), size: data.count, crc: ExportZip.crc32(data))
    }

    private func deflated(_ name: String, _ text: String) -> Part { deflated(name, Array(text.utf8)) }

    private func stored(_ name: String, _ data: [UInt8]) -> Part {
        Part(name: name, packed: data, size: data.count, crc: ExportZip.crc32(data), method: 0)
    }

    private func w16(_ o: inout [UInt8], _ v: Int) { o += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }

    private func w32(_ o: inout [UInt8], _ v: Int) { w16(&o, v); w16(&o, v >> 16) }

    private func w64(_ o: inout [UInt8], _ v: Int) { w32(&o, v); w32(&o, v >> 32) }

    /// A zip written by hand, so that descriptors, zip64 and lying sizes can be had.
    private func build(_ parts: [Part], descriptors: Bool = false, zip64: Bool = false, comment: String = "") -> [UInt8] {
        var o: [UInt8] = []
        var dir: [UInt8] = []
        for p in parts {
            let name = Array(p.name.utf8)
            let at = o.count
            let flags = p.flags | (descriptors ? 8 : 0)
            w32(&o, 0x04034B50); w16(&o, 20); w16(&o, flags); w16(&o, p.method); w32(&o, 0)
            w32(&o, descriptors ? 0 : Int(p.crc)); w32(&o, descriptors ? 0 : p.packed.count); w32(&o, descriptors ? 0 : p.size)
            w16(&o, name.count); w16(&o, 0)
            o += name
            o += p.packed
            if descriptors { w32(&o, 0x08074B50); w32(&o, Int(p.crc)); w32(&o, p.packed.count); w32(&o, p.size) }

            w32(&dir, 0x02014B50); w16(&dir, 45); w16(&dir, 20); w16(&dir, flags); w16(&dir, p.method); w32(&dir, 0); w32(&dir, Int(p.crc))
            w32(&dir, zip64 ? 0xFFFFFFFF : p.packed.count); w32(&dir, zip64 ? 0xFFFFFFFF : p.size)
            w16(&dir, name.count); w16(&dir, zip64 ? 28 : 0); w16(&dir, 0); w16(&dir, 0); w16(&dir, 0); w32(&dir, 0)
            w32(&dir, zip64 ? 0xFFFFFFFF : at)
            dir += name
            if zip64 { w16(&dir, 1); w16(&dir, 24); w64(&dir, p.size); w64(&dir, p.packed.count); w64(&dir, at) }
        }
        let offset = o.count
        o += dir
        if zip64 {
            let record = o.count
            w32(&o, 0x06064B50); w64(&o, 44); w16(&o, 45); w16(&o, 45); w32(&o, 0); w32(&o, 0)
            w64(&o, parts.count); w64(&o, parts.count); w64(&o, dir.count); w64(&o, offset)
            w32(&o, 0x07064B50); w32(&o, 0); w64(&o, record); w32(&o, 1)
        }
        w32(&o, 0x06054B50); w16(&o, 0); w16(&o, 0)
        w16(&o, zip64 ? 0xFFFF : parts.count); w16(&o, zip64 ? 0xFFFF : parts.count)
        w32(&o, zip64 ? 0xFFFFFFFF : dir.count); w32(&o, zip64 ? 0xFFFFFFFF : offset)
        w16(&o, comment.utf8.count)
        o += Array(comment.utf8)
        return o
    }

    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private func refused(_ act: @autoclosure () throws -> Any, _ line: UInt = #line) -> PdfReadException? {
        do {
            _ = try act()
            XCTFail("expected a refusal", line: line)
            return nil
        } catch let e as PdfReadException {
            return e
        } catch {
            XCTFail("\(error)", line: line)
            return nil
        }
    }

    func test_readsWhatTheWriterMakes() throws {
        let big = Array(String(repeating: "<row>çay</row>", count: 500).utf8)
        let zip = try ZipReader.open(ExportZip.make([
            ExportZipEntry("[Content_Types].xml", Array("<Types/>".utf8)), ExportZipEntry("xl/sheet1.xml", big), ExportZipEntry("empty.txt", [])]))
        XCTAssertEqual(zip.names, ["[Content_Types].xml", "xl/sheet1.xml", "empty.txt"])
        XCTAssertEqual(try zip.read("xl/sheet1.xml"), big)
        XCTAssertEqual(text(try zip.read("[Content_Types].xml")), "<Types/>")
        XCTAssertTrue(try zip.read("empty.txt").isEmpty)
    }

    func test_namesAreCaseInsensitiveAndFoldersAreNotListed() throws {
        let zip = try ZipReader.open(build([stored("word/", []), deflated("Word/Document.xml", "<d/>")]))
        XCTAssertEqual(zip.names, ["Word/Document.xml"])
        XCTAssertTrue(zip.contains("word/document.xml"))
        XCTAssertEqual(text(try zip.read("word/document.xml")), "<d/>")
        _ = refused(try zip.read("word/other.xml"))
    }

    func test_readsStoredEntriesDataDescriptorsAndComments() throws {
        let parts = [stored("a.txt", Array("stored".utf8)), deflated("b.txt", "deflated deflated deflated")]
        let zip = try ZipReader.open(build(parts, descriptors: true, comment: "hello"))
        XCTAssertEqual(text(try zip.read("a.txt")), "stored")
        XCTAssertEqual(text(try zip.read("b.txt")), "deflated deflated deflated")
    }

    func test_readsZip64SizesAndOffsets() throws {
        let zip = try ZipReader.open(build([deflated("a.xml", "first"), deflated("b.xml", "second")], zip64: true))
        XCTAssertEqual(zip.names, ["a.xml", "b.xml"])
        XCTAssertEqual(text(try zip.read("b.xml")), "second")
    }

    func test_refusesAFileThatIsNotAZipOrIsCutShort() {
        _ = refused(try ZipReader.open(Array("not a zip at all, just text".utf8)))
        _ = refused(try ZipReader.open([]))
        let good = build([deflated("a.xml", "<a/>")])
        _ = refused(try ZipReader.open(Array(good[..<(good.count - 5)])))
        // The directory points past the file.
        var bad = good
        var at: [UInt8] = []
        w32(&at, good.count)
        bad.replaceSubrange((bad.count - 6)..<(bad.count - 2), with: at)
        _ = refused(try ZipReader.open(bad))
    }

    func test_refusesAnEntryWhoseDataIsDamaged() throws {
        let good = build([deflated("a.xml", "<a>some text some text</a>")])
        XCTAssertEqual(text(try ZipReader.open(good).read("a.xml")), "<a>some text some text</a>")
        var wrongCrc = deflated("a.xml", "<a/>")
        wrongCrc.crc = 1234
        _ = refused(try ZipReader.open(build([wrongCrc])).read("a.xml"))
        var truncated = deflated("a.xml", "<a>some text some text some text</a>")
        truncated.packed = Array(truncated.packed.dropLast(3))
        _ = refused(try ZipReader.open(build([truncated])).read("a.xml"))
    }

    func test_refusesSizesThatLie() throws {
        var small = deflated("a.bin", [UInt8](repeating: 0, count: 100_000))
        small.size = 10
        let inflated = refused(try ZipReader.open(build([small])).read("a.bin"))
        XCTAssertEqual(inflated?.problem, .unsupported)
        var large = deflated("a.bin", "short")
        large.size = 5000
        _ = refused(try ZipReader.open(build([large])).read("a.bin"))
        var lie = stored("a.bin", Array("12345".utf8))
        lie.size = 4
        _ = refused(try ZipReader.open(build([lie])).read("a.bin"))
    }

    func test_refusesNamesThatLeaveThePackageAndRepeats() {
        _ = refused(try ZipReader.open(build([deflated("../evil.xml", "x")])))
        _ = refused(try ZipReader.open(build([deflated("a/../../evil.xml", "x")])))
        _ = refused(try ZipReader.open(build([deflated("a\\..\\evil.xml", "x")])))
        _ = refused(try ZipReader.open(build([deflated("/etc/passwd", "x")])))
        _ = refused(try ZipReader.open(build([deflated("a.xml", "x"), deflated("A.XML", "y")])))
    }

    func test_refusesEncryptedAndUnknownMethods() {
        var encrypted = deflated("a.xml", "x")
        encrypted.flags = 1
        XCTAssertEqual(refused(try ZipReader.open(build([encrypted])))?.problem, .unsupported)
        var odd = deflated("a.xml", "x")
        odd.method = 12
        XCTAssertEqual(refused(try ZipReader.open(build([odd])))?.problem, .unsupported)
    }

    func test_refusesTooManyEntries() throws {
        let zip = build((0..<50).map { deflated("p\($0).xml", "x") })
        XCTAssertEqual(try ZipReader.open(zip, ZipLimits(maxEntries: 50)).names.count, 50)
        _ = refused(try ZipReader.open(zip, ZipLimits(maxEntries: 49)))
    }

    func test_refusesEntriesAndTotalsOverTheLimit() throws {
        let zip = build([deflated("a.bin", [UInt8](repeating: 0, count: 3000)), deflated("b.bin", [UInt8](repeating: 0, count: 3000))])
        _ = try ZipReader.open(zip, ZipLimits(maxTotal: 6000, maxEntry: 3000))
        _ = refused(try ZipReader.open(zip, ZipLimits(maxTotal: 5999)))
        _ = refused(try ZipReader.open(zip, ZipLimits(maxEntry: 2999)))
    }

    func test_refusesAnEntryPackedTooTightly() throws {
        // 8 MB of zeros packs about a thousand to one.
        let bomb = build([deflated("bomb.xml", [UInt8](repeating: 0, count: 8 << 20))])
        XCTAssertLessThan(bomb.count, 40_000)
        XCTAssertTrue(refused(try ZipReader.open(bomb))?.message.contains("too tightly") ?? false)
        XCTAssertEqual(try ZipReader.open(bomb, ZipLimits(maxRatio: 5000)).read("bomb.xml").count, 8 << 20)
        // Text that packs ordinarily is fine at any size.
        let big = Array((0..<200_000).map { "<c r=\"A\($0)\" v=\"\($0 * 7919 % 10007)\"/>" }.joined().utf8)
        XCTAssertEqual(try ZipReader.open(build([deflated("s.xml", big)])).read("s.xml").count, big.count)
    }

    func test_manyEntriesCannotAddUpPastTheTotal() throws {
        let data = [UInt8](repeating: 0, count: 1 << 20)
        let part = deflated("e", data)
        let many = build((0..<400).map { i -> Part in var p = part; p.name = "e\(i)"; return p })
        _ = refused(try ZipReader.open(many, ZipLimits(maxTotal: 64 << 20, maxRatio: 5000)))
        XCTAssertEqual(try ZipReader.open(many, ZipLimits(maxTotal: 400 << 20, maxRatio: 5000)).names.count, 400)
    }

    func test_zip64ValuesNearTheTopOfTheRangeAreRefusedNotThrown() throws {
        let good = build([stored("a.xml", Array("<a/>".utf8))], zip64: true)
        let record = good.count - 22 - 20 - 56
        var directoryBytes: [UInt8] = []
        directoryBytes += good[(record + 48)..<(record + 52)]
        let directory = Int(directoryBytes[0]) | Int(directoryBytes[1]) << 8 | Int(directoryBytes[2]) << 16 | Int(directoryBytes[3]) << 24
        let extra = directory + 46 + "a.xml".utf8.count + 4
        func patched(_ at: Int, _ value: Int) -> [UInt8] {
            var copy = good
            var bytes: [UInt8] = []
            w64(&bytes, value)
            copy.replaceSubrange(at..<(at + 8), with: bytes)
            return copy
        }

        XCTAssertEqual(text(try ZipReader.open(good).read("a.xml")), "<a/>")
        _ = refused(try ZipReader.open(patched(good.count - 22 - 12, 0x7FFFFFFFFFFFFFFE)))
        _ = refused(try ZipReader.open(patched(record + 48, Int.max)))
        _ = refused(try ZipReader.open(patched(record + 40, Int.max - 1)))
        _ = refused(try ZipReader.open(patched(extra + 16, Int.max - 1)).read("a.xml"))
        _ = refused(try ZipReader.open(patched(extra + 8, Int.max - 10)).read("a.xml"))
    }

    func test_declaringAHugeSizeDoesNotAllocate() throws {
        var huge = deflated("a.bin", "tiny")
        huge.size = Int(Int32.max)
        let zip = build([huge])
        _ = refused(try ZipReader.open(zip))
        let open = try ZipReader.open(zip, ZipLimits(maxEntries: 20_000, maxTotal: Int.max, maxEntry: Int.max, maxRatio: Int(Int32.max)))
        _ = refused(try open.read("a.bin"))
    }
}
