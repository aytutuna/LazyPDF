import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/TaggedFile.cs: a small tagged one-page file made by hand: Document with H1,
// P and Figure, one parent tree array. The C# SortedDictionary of objects is a Dictionary written in key order.

enum TaggedFile {
    static let content =
        "/H1 <</MCID 0>> BDC BT /F2 18 Tf 72 700 Td (Head) Tj ET EMC\n" +
        "/P <</MCID 1>> BDC BT /F1 11 Tf 72 670 Td (Body text) Tj ET EMC\n" +
        "/Figure <</MCID 2>> BDC q 50 0 0 50 72 600 cm /Im1 Do Q EMC\n"

    /// The structure objects 8 to 13; a test may replace or add entries before the file is written.
    static func objects() -> [Int: String] {
        [
            8: "<</Type /StructTreeRoot /K 9 0 R /ParentTree 13 0 R /ParentTreeNextKey 1 /RoleMap <</Heading /H1 /Weird /Nope>> /ClassMap <</Fancy <</O /Layout>>>>>>",
            9: "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R]>>",
            10: "<</Type /StructElem /S /H1 /P 9 0 R /Pg 3 0 R /K 0 /T (Head) /Lang (tr) /A <</O /Layout /Placement /Block>> /C /Fancy>>",
            11: "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K 1 /ActualText (Body text)>>",
            12: "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2 /Alt (A picture)>>",
            13: "<</Nums [0 [10 0 R 11 0 R 12 0 R]]>>",
        ]
    }

    static func build(_ edit: ((inout [Int: String]) -> Void)? = nil, catalog: String = "/Lang (en-US)", content: String = TaggedFile.content) -> [UInt8] {
        var made = Self.objects()
        edit?(&made)
        return AccessKit.build(1, { _ in content }, catalog: "/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> \(catalog)",
                               pageEntries: "/StructParents 0 /Tabs /S", more: { pdf in
            for (number, body) in made.sorted(by: { $0.key < $1.key }) { pdf.obj(number, body) }
        })
    }

    static func open(_ edit: ((inout [Int: String]) -> Void)? = nil, catalog: String = "/Lang (en-US)") throws -> PdfDocument {
        try PdfDocument.open(build(edit, catalog: catalog))
    }
}
