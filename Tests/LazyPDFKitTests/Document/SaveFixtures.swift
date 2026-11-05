import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SaveFixtures.cs: the same small two-page file (catalog 1, page tree
// 2, pages 3 and 4, contents 5 and 6, info 7) laid out the ways a file can be: classic table, cross-reference
// stream, objects in object streams, a hybrid, and encrypted.

enum SaveFixtures {
    static let kinds = ["table", "stream", "objects", "hybrid", "aes128", "aes256", "aes256objects"]

    static let fileId: [UInt8] = (1...16).map { UInt8($0) }

    private static let bodies = [
        "<</Type /Catalog /Pages 2 0 R>>",
        "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300] /Resources <</Font <</F1 <</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>>>>>>>",
        "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>",
        "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>",
    ]

    static let pageOne = "BT /F1 12 Tf 20 100 Td (Page one) Tj ET"
    static let pageTwo = "BT /F1 12 Tf 20 100 Td (Page two) Tj ET"
    static let info = "<</Title (Original title) /Author (Someone)>>"

    static func make(_ kind: String) throws -> [UInt8] {
        switch kind {
        case "table": return table()
        case "stream": return layout(hybrid: false)
        case "hybrid": return layout(hybrid: true)
        case "objects": return try rewrite(table(), PdfSaveOptions(useObjectStreams: true))
        case "aes128": return try rewrite(table(), PdfSaveOptions(security: secure(.aes128), documentId: fileId))
        case "aes256": return try rewrite(table(), PdfSaveOptions(security: secure(.aes256)))
        case "aes256objects": return try rewrite(table(), PdfSaveOptions(useObjectStreams: true, security: secure(.aes256)))
        default: preconditionFailure(kind)
        }
    }

    static func secure(_ strength: PdfCryptStrength) -> PdfSecurity {
        PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: strength,
                           firstId: fileId, random: SeededRandom(5))
    }

    static func rewrite(_ file: [UInt8], _ options: PdfSaveOptions) throws -> [UInt8] {
        try PdfDocument.open(file).saveRewrite(options)
    }

    static func table() -> [UInt8] {
        let pdf = TestPdf()
        for (i, body) in bodies.enumerated() { pdf.obj(i + 1, body) }
        pdf.stream(5, "", pageOne)
        pdf.stream(6, "", pageTwo)
        pdf.obj(7, info)
        let id = Hex.string(fileId)
        return pdf.finish("/Root 1 0 R /Info 7 0 R /ID [<\(id)> <\(id)>]")
    }

    /// Cross-reference stream 8; with `hybrid` a classic table instead, page 3 in object stream 8 and the stream 9
    /// that lists it, which the table's /XRefStm points at.
    private static func layout(hybrid: Bool) -> [UInt8] {
        var file: [UInt8] = []
        var offsets: [Int: Int] = [:]
        func write(_ text: String) { file += TestPdf.latin(text) }
        func obj(_ number: Int, _ body: String) {
            offsets[number] = file.count
            write("\(number) 0 obj\n\(body)\nendobj\n")
        }
        func stream(_ number: Int, _ entries: String, _ data: String) {
            obj(number, "<<\(entries) /Length \(data.unicodeScalars.count)>>\nstream\n\(data)\nendstream")
        }
        let id = Hex.string(fileId)

        write("%PDF-1.5\n")
        for (i, body) in bodies.enumerated() where !(hybrid && i == 2) { obj(i + 1, body) }
        stream(5, "", pageOne)
        stream(6, "", pageTwo)
        obj(7, info)
        if !hybrid {
            let start = file.count
            var rows: [UInt8] = []
            func row(_ type: Int, _ second: Int, _ third: Int) {
                rows.append(UInt8(type))
                for b in stride(from: 3, through: 0, by: -1) { rows.append(UInt8(truncatingIfNeeded: second >> (b * 8))) }
                rows.append(UInt8(third))
            }
            row(0, 0, 255)
            for number in offsets.keys.sorted() { row(1, offsets[number] ?? 0, 0) }
            row(1, start, 0)
            let data = TestPdf.text(rows)
            write("8 0 obj\n<</Type /XRef /Size 9 /W [1 4 1] /Root 1 0 R /Info 7 0 R /ID [<\(id)> <\(id)>] /Length \(data.unicodeScalars.count)>>\nstream\n\(data)\nendstream\nendobj\n")
            write("startxref\n\(start)\n%%EOF\n")
            return file
        }

        let page = bodies[2]
        let header = "3 0 "
        stream(8, "/Type /ObjStm /N 1 /First \(header.count)", header + page)
        let xrefStream = file.count
        let row: [UInt8] = [2, 0, 0, 0, 8, 0]
        stream(9, "/Type /XRef /Size 10 /W [1 4 1] /Index [3 1]", TestPdf.text(row))
        let table = file.count
        var text = "xref\n0 10\n0000000000 65535 f \n"
        for n in 1..<10 {
            if let at = offsets[n] {
                text += String(format: "%010ld 00000 n \n", at)
            } else {
                text += "0000000000 00000 f \n"
            }
        }
        text += "trailer\n<</Size 10 /Root 1 0 R /Info 7 0 R /ID [<\(id)> <\(id)>] /XRefStm \(xrefStream)>>\nstartxref\n\(table)\n%%EOF\n"
        write(text)
        return file
    }

    static func title(_ document: PdfDocument) -> String {
        Latin1.string((document.info?["Title"] as? PdfString)?.bytes ?? [])
    }

    /// A new title, new text on page two, and a new object the catalog points at.
    static func edit(_ document: PdfDocument, _ title: String = "New title") throws {
        document.info?["Title"] = PdfString(bytes: Latin1.bytes(title), isHex: false)
        let contents = document.resolve(document.pages[1].dictionary["Contents"], as: PdfStream.self)
        contents?.data = TestPdf.latin("BT /F1 12 Tf 20 100 Td (Changed) Tj ET")
        let note = PdfDictionary()
        note.add("Note", PdfString(bytes: Latin1.bytes("Added note"), isHex: false))
        document.catalog["Extra"] = try document.add(note)
    }
}
