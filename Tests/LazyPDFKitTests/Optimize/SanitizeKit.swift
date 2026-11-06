import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeKit.cs: the same helpers.

enum SanitizeKit {
    static let markers = [
        "MARKERJS1", "MARKERJS2", "MARKERJS3", "MARKERJS4", "MARKERATTACH", "MARKERPATH", "MARKERXMP", "MARKERTITLE", "MARKERAUTHOR", "MARKERPIECE",
        "MARKERBASE", "MARKERSPIDER", "MARKERNOTE", "MARKERHL", "MARKERURL", "MARKERLAUNCH", "MARKERFORM", "MARKEROLDREV", "MARKERTHUMB",
    ]

    /// A file with something of every kind in it, each marked, a first version with an old title, and a
    /// second that replaced it. Page text is "Visible text".
    static func dirty() throws -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 20 0 R /AA <</WC 21 0 R>> /Metadata 24 0 R /AcroForm 25 0 R /AF [23 0 R] " +
            "/Names <</JavaScript <</Names [(js1) 22 0 R]>> /EmbeddedFiles <</Names [(att.txt) 23 0 R]>> /IDS <</Names []>>>> " +
            "/PieceInfo <</App <</Data (MARKERPIECE)>>>> /URI <</Base (http://MARKERBASE.example/)>> /SpiderInfo <</X (MARKERSPIDER)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Im0 26 0 R>>>> /AA <</O 21 0 R>> /Thumb 37 0 R " +
            "/Annots [27 0 R 28 0 R 29 0 R 30 0 R 31 0 R 34 0 R]>>")
        pdf.stream(4, "", "BT /F1 12 Tf 10 150 Td (Visible text) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(20, "<</S /JavaScript /JS (app.alert\\('MARKERJS1'\\))>>")
        pdf.obj(21, "<</S /JavaScript /JS 32 0 R>>")
        pdf.obj(22, "<</S /JavaScript /JS (MARKERJS3)>>")
        pdf.obj(23, "<</Type /Filespec /F (C:\\\\Users\\\\bob\\\\MARKERPATH.txt) /UF (C:\\\\Users\\\\bob\\\\MARKERPATH.txt) /EF <</F 33 0 R>>>>")
        pdf.stream(24, "/Type /Metadata /Subtype /XML", "<x:xmpmeta>MARKERXMP</x:xmpmeta>")
        pdf.obj(25, "<</Fields [34 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 5 0 R>>>>>>")
        pdf.stream(26, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Alt (MARKERALT)", "abcd")
        pdf.stream(37, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", "MARKERTHUMB")
        pdf.obj(27, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (MARKERNOTE)>>")
        pdf.obj(28, "<</Type /Annot /Subtype /Highlight /Rect [0 0 10 10] /QuadPoints [0 10 10 10 0 0 10 0] /Contents (MARKERHL)>>")
        pdf.obj(29, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://MARKERURL.example/)>>>>")
        pdf.obj(30, "<</Type /Annot /Subtype /Link /Rect [20 0 30 10] /A <</S /Launch /F (MARKERLAUNCH.exe)>>>>")
        pdf.obj(31, "<</Type /Annot /Subtype /FileAttachment /Rect [40 0 50 10] /FS 23 0 R>>")
        pdf.stream(32, "", "app.alert('MARKERJS2')")
        pdf.stream(33, "/Type /EmbeddedFile", "MARKERATTACH")
        pdf.obj(34, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (MARKERFORM) /Rect [10 100 150 120] /P 3 0 R /AA <</K 35 0 R>>>>")
        pdf.obj(35, "<</S /JavaScript /JS (MARKERJS4)>>")
        pdf.obj(36, "<</Title (MARKEROLDREV) /Author (MARKERAUTHOR)>>")
        let first = pdf.finish("/Root 1 0 R /Info 36 0 R")
        let document = try PdfDocument.open(first)
        document.info?["Title"] = PdfString(bytes: Latin1.bytes("MARKERTITLE"), isHex: false)
        return try document.saveIncremental()
    }

    static func count(_ findings: [SanitizeFinding], _ item: SanitizeItem) -> Int {
        findings.first { $0.item == item }?.count ?? 0
    }
}
