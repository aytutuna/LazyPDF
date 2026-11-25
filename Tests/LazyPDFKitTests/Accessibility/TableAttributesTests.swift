import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/TableAttributesTests.cs: the same cases.

final class TableAttributesTests: XCTestCase {
    private func grid() throws -> (document: PdfDocument, tree: StructureTree, table: StructElement, rows: [StructElement]) {
        let document = try PdfDocument.open(AccessKit.build(1) { _ in "" })
        let tree = StructureTree.create(document)
        let root = StructElement("Document")
        try tree.add(nil, root)
        let table = StructElement("Table")
        try tree.add(root, table)
        var rows: [StructElement] = []
        for _ in 0..<2 {
            let row = StructElement("TR")
            try tree.add(table, row)
            for _ in 0..<2 { try tree.add(row, StructElement("TD")) }
            rows.append(row)
        }
        return (document, tree, table, rows)
    }

    private func dict(_ owner: String, _ more: [(String, PdfObject)] = []) -> PdfDictionary {
        let d = PdfDictionary()
        d["O"] = PdfName(owner)
        for (key, value) in more { d[key] = value }
        return d
    }

    private func strings(_ values: [String]) -> PdfArray { PdfArray(values.map { PdfText.toObject($0) as PdfObject }) }

    func test_readsOneDictionary() throws {
        let (_, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        cell.dictionary["A"] = dict("Table", [("Scope", PdfName("Both")), ("RowSpan", PdfNumber(2)), ("ColSpan", PdfNumber(3)), ("Headers", strings(["a", "b"]))])

        let attributes = tree.tableAttributes(cell)
        XCTAssertEqual(attributes.scope, .both)
        XCTAssertEqual(attributes.rowSpan, 2)
        XCTAssertEqual(attributes.colSpan, 3)
        XCTAssertEqual(attributes.headers, ["a", "b"])
    }

    func test_readsAnArrayWithOtherOwnersAndRevisions() throws {
        let (_, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let layout = dict("Layout", [("Scope", PdfName("Row")), ("RowSpan", PdfNumber(9))])
        let table = dict("Table", [("Scope", PdfName("Column"))])
        let second = dict("Table", [("Scope", PdfName("Row")), ("ColSpan", PdfNumber(4))])
        cell.dictionary["A"] = PdfArray([layout, PdfNumber(1), table, PdfNumber(0), second])

        let attributes = tree.tableAttributes(cell)
        XCTAssertEqual(attributes.scope, .column)
        XCTAssertNil(attributes.rowSpan)
        XCTAssertEqual(attributes.colSpan, 4)
        XCTAssertTrue(attributes.headers.isEmpty)
    }

    func test_readsThroughReferences() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let inner = try document.add(dict("Table", [("Scope", PdfName("Row"))]))
        cell.dictionary["A"] = try document.add(PdfArray([inner]))

        XCTAssertEqual(tree.tableAttributes(cell).scope, .row)
    }

    func test_malformedAttributesReadAsNotSet() throws {
        let (_, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let scoped = PdfDictionary()
        scoped["Scope"] = PdfName("Row")

        let junk: [PdfObject] = [PdfNumber(3), PdfName("Table"), PdfArray([PdfNumber(1), PdfName("x")]), scoped]
        for value in junk {
            cell.dictionary["A"] = value
            XCTAssertNil(tree.tableAttributes(cell).scope)
            XCTAssertNil(tree.tableAttributes(cell).rowSpan)
        }

        cell.dictionary["A"] = dict("Table", [("Scope", PdfName("Rows")), ("RowSpan", PdfNumber(0)), ("ColSpan", PdfText.toObject("x")), ("Headers", PdfNumber(5))])
        let attributes = tree.tableAttributes(cell)
        XCTAssertNil(attributes.scope)
        XCTAssertNil(attributes.rowSpan)
        XCTAssertNil(attributes.colSpan)
        XCTAssertTrue(attributes.headers.isEmpty)

        cell.dictionary["A"] = dict("Table", [("RowSpan", PdfNumber(-2)), ("Headers", PdfArray([PdfNumber(1), PdfText.toObject("ok"), PdfArray([PdfNumber(2)])]))])
        XCTAssertNil(tree.tableAttributes(cell).rowSpan)
        XCTAssertEqual(tree.tableAttributes(cell).headers, ["ok"])

        cell.dictionary.remove("A")
        XCTAssertNil(tree.tableAttributes(cell).scope)
    }

    func test_setCreatesTheDictionaryAndRoundTrips() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]

        tree.setTableAttributes(cell, TableAttributes(scope: .row, rowSpan: 2, colSpan: 3))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        let td = try XCTUnwrap(read.elements.first { $0.type == "TD" })
        let back = read.tableAttributes(td)
        XCTAssertEqual(back.scope, .row)
        XCTAssertEqual(back.rowSpan, 2)
        XCTAssertEqual(back.colSpan, 3)
        XCTAssertEqual(again.name(again.dict(td.dictionary, "A"), "O"), "Table")
    }

    func test_setKeepsOtherOwnersAndRevisionNumbers() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let layout = dict("Layout", [("Placement", PdfName("Block"))])
        cell.dictionary["A"] = PdfArray([layout, PdfNumber(2), dict("Table", [("Scope", PdfName("Row")), ("Headers", strings(["h"]))]), PdfNumber(3)])

        tree.setTableAttributes(cell, TableAttributes(scope: .column, rowSpan: 4))
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        let td = try XCTUnwrap(read.elements.first { $0.type == "TD" })
        let list = try XCTUnwrap(again.array(td.dictionary, "A"))
        XCTAssertEqual(list.items.count, 4)
        XCTAssertEqual(again.name(list.items[0] as? PdfDictionary, "Placement"), "Block")
        XCTAssertEqual((list.items[1] as? PdfNumber)?.integer, 2)
        XCTAssertEqual((list.items[3] as? PdfNumber)?.integer, 3)
        let attributes = read.tableAttributes(td)
        XCTAssertEqual(attributes.scope, .column)
        XCTAssertEqual(attributes.rowSpan, 4)
        XCTAssertTrue(attributes.headers.isEmpty)
    }

    func test_setAddsATableDictionaryNextToAnotherOwners() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        cell.dictionary["A"] = dict("Layout", [("Placement", PdfName("Block"))])

        tree.setTableAttributes(cell, TableAttributes(scope: .row))

        let list = try XCTUnwrap(cell.dictionary["A"] as? PdfArray)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(document.name(list.items[0] as? PdfDictionary, "O"), "Layout")
        XCTAssertEqual(tree.tableAttributes(cell).scope, .row)
    }

    func test_setReplacesJunkAndClearsWhatIsEmpty() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        cell.dictionary["A"] = PdfNumber(7)

        tree.setTableAttributes(cell, TableAttributes(scope: .both, rowSpan: 1, colSpan: 1))
        let table = try XCTUnwrap(cell.dictionary["A"] as? PdfDictionary)
        XCTAssertFalse(table.containsKey("RowSpan"))
        XCTAssertFalse(table.containsKey("ColSpan"))

        tree.setTableAttributes(cell, TableAttributes())
        XCTAssertNil(cell.dictionary["A"])

        cell.dictionary["A"] = PdfArray([dict("Layout"), dict("Table", [("Scope", PdfName("Row"))]), PdfNumber(1)])
        tree.setTableAttributes(cell, TableAttributes())
        let left = try XCTUnwrap(cell.dictionary["A"] as? PdfArray)
        XCTAssertEqual(left.items.count, 1)
        XCTAssertEqual(document.name(left.items[0] as? PdfDictionary, "O"), "Layout")
    }

    func test_settingWhatIsThereLeavesTheObjectsAlone() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        tree.setTableAttributes(cell, TableAttributes(scope: .row, rowSpan: 2))
        try tree.write(document)
        let again = try PdfDocument.open(try document.saveIncremental())
        let read = try XCTUnwrap(StructureTree.read(again))
        let td = try XCTUnwrap(read.elements.first { $0.type == "TD" })
        let before = again.dict(td.dictionary, "A")

        read.setTableAttributes(td, read.tableAttributes(td))
        try read.write(again)

        assertSame(before, again.dict(td.dictionary, "A"))
        XCTAssertTrue(again.changedObjects().isEmpty)
    }

    func test_headersGetIdsThatNoElementHas() throws {
        let (document, tree, _, rows) = try grid()
        let head = rows[0].children
        let cell = rows[1].children[0]
        head[0].id = "th1"

        tree.setHeaders(cell, head)

        XCTAssertEqual(head[0].id, "th1")
        XCTAssertEqual(head[1].id, "th2")
        XCTAssertEqual(tree.tableAttributes(cell).headers, ["th1", "th2"])
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        let found = read.elements.filter { $0.type == "TR" }[1].children[0]
        XCTAssertEqual(read.tableAttributes(found).headers, ["th1", "th2"])
        let ids = PdfNameTree.read(again, read.dictionary["IDTree"])
        XCTAssertEqual(ids.map { PdfNameTree.textOf($0.key) }.sorted(), ["th1", "th2"])
        for entry in ids {
            let number = (entry.value as? PdfReference)?.number
            let target = try XCTUnwrap(read.elements.first { $0.reference?.number == number })
            XCTAssertEqual(target.id, PdfNameTree.textOf(entry.key))
        }
    }

    func test_aHeaderRowBecomesHeaderCells() throws {
        let (document, tree, _, rows) = try grid()
        tree.roleMap["Cell"] = "TD"
        try tree.add(rows[0], StructElement("Cell"))
        let first = rows[0].children[0]
        first.dictionary["A"] = PdfArray([dict("Layout", [("Placement", PdfName("Block"))]), dict("Table", [("Scope", PdfName("Row")), ("RowSpan", PdfNumber(2))])])

        XCTAssertEqual(tree.makeHeaderRow(rows[0]), 3)

        for c in rows[0].children {
            XCTAssertEqual(c.type, "TH")
            XCTAssertEqual(tree.tableAttributes(c).scope, .column)
        }
        XCTAssertEqual(tree.tableAttributes(first).rowSpan, 2)
        let list = try XCTUnwrap(first.dictionary["A"] as? PdfArray)
        XCTAssertEqual(document.name(list.items[0] as? PdfDictionary, "O"), "Layout")
        for c in rows[1].children { XCTAssertEqual(c.type, "TD") }
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        let read = try XCTUnwrap(StructureTree.read(again))
        let header = try XCTUnwrap(read.elements.first { $0.type == "TR" })
        for c in header.children { XCTAssertEqual(read.tableAttributes(c).scope, .column) }
    }

    func test_aRowOfCustomHeaderCellsKeepsTheirType() throws {
        let (_, tree, table, _) = try grid()
        tree.roleMap["Head"] = "TH"
        tree.roleMap["Line"] = "TR"
        let row = StructElement("Line")
        try tree.add(table, row)
        let cell = StructElement("Head")
        try tree.add(row, cell)
        try tree.add(row, StructElement("P"))

        XCTAssertEqual(tree.makeHeaderRow(row), 1)
        XCTAssertEqual(cell.type, "Head")
        XCTAssertEqual(tree.tableAttributes(cell).scope, .column)
    }

    func test_onlyARowIsTurnedIntoHeaders() throws {
        let (_, tree, table, rows) = try grid()

        XCTAssertEqual(tree.makeHeaderRow(table), 0)
        XCTAssertEqual(tree.makeHeaderRow(rows[0].children[0]), 0)
        for c in rows[0].children { XCTAssertEqual(c.type, "TD") }
    }

    func test_clearingAValueAlsoClearsItInLaterDictionaries() throws {
        let (_, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let first = dict("Table", [("Scope", PdfName("Column"))])
        let second = dict("Table", [("RowSpan", PdfNumber(3)), ("Scope", PdfName("Row")), ("Headers", strings(["a"]))])
        cell.dictionary["A"] = PdfArray([first, PdfNumber(0), second, PdfNumber(1)])

        var attributes = tree.tableAttributes(cell)
        attributes.rowSpan = 1
        attributes.headers = []
        tree.setTableAttributes(cell, attributes)
        XCTAssertNil(tree.tableAttributes(cell).rowSpan)
        XCTAssertTrue(tree.tableAttributes(cell).headers.isEmpty)
        XCTAssertEqual(tree.tableAttributes(cell).scope, .column)

        attributes = tree.tableAttributes(cell)
        attributes.scope = nil
        tree.setTableAttributes(cell, attributes)
        XCTAssertNil(tree.tableAttributes(cell).scope)
        XCTAssertNil(cell.dictionary["A"])
    }

    func test_laterDictionariesKeepWhatIsNotATableValue() throws {
        let (document, tree, _, rows) = try grid()
        let cell = rows[0].children[0]
        let second = dict("Table", [("RowSpan", PdfNumber(3)), ("Summary", PdfText.toObject("s"))])
        let shared = try document.add(second)
        cell.dictionary["A"] = PdfArray([dict("Table", [("Scope", PdfName("Row"))]), shared])

        tree.setTableAttributes(cell, TableAttributes(scope: .row))

        XCTAssertNotNil(second["RowSpan"])
        XCTAssertNil(tree.tableAttributes(cell).rowSpan)
        let stored = try XCTUnwrap(document.resolve((cell.dictionary["A"] as? PdfArray)?.items[1]) as? PdfDictionary)
        XCTAssertEqual(PdfText.read(document, stored, "Summary"), "s")
    }

    func test_headersKeepTheirStoredBytes() throws {
        let (_, tree, _, rows) = try grid()
        let cell = rows[1].children[0]
        let raw: [UInt8] = [0xFE, 0xFF, 0x00, 0x74, 0x00, 0x68, 0x00, 0x31]
        cell.dictionary["A"] = dict("Table", [("Headers", PdfArray([PdfString(bytes: raw, isHex: true)]))])

        var attributes = tree.tableAttributes(cell)
        attributes.scope = .row
        tree.setTableAttributes(cell, attributes)
        attributes = tree.tableAttributes(cell)
        attributes.headers = ["th1", "new"]
        tree.setTableAttributes(cell, attributes)

        let headers = try XCTUnwrap(((cell.dictionary["A"] as? PdfDictionary)?["Headers"] as? PdfArray)?.items)
        XCTAssertEqual((headers[0] as? PdfString)?.bytes, raw)
        XCTAssertEqual(PdfText.decode((headers[1] as? PdfString)?.bytes ?? []), "new")
    }
}
