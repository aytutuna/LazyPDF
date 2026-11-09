import Foundation

// Follows windows/LazyPDF.App.Tests/Tools/edit/EditPdf.cs.

/// A one page file written by hand: Helvetica as /F1, the content as given.
enum EditPdf {
    static func make(_ content: String, pageKeys: String = "") -> [UInt8] {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> \(pageKeys) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }

    static let paragraph = "BT /F1 12 Tf 14 TL 50 700 Td (The first line of this text runs along) Tj T* (the second line and keeps going here) Tj T* (and the third line ends it) Tj ET"
}
