import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Document/DocumentGolden.cs. One line of input is "<op> <name> [<how>]": a file
// built by both sides (the names below), read, repaired, updated or rewritten, and what came of it, in text.
// A file that holds nothing random or compressed is written out byte for byte, with the second string of /ID set
// to zeros; any other is described as it reads back. Deflate output differs between implementations, so nothing
// that hangs on the size of compressed data is printed for the files that have some.
enum DocumentGolden {
    private static let exact = ["table", "stream", "hybrid"]

    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let words = line.components(separatedBy: " ")
            output += "> \(line)\n"
            for result in try op(words[0], words[1], words.count > 2 ? words[2] : nil) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ name: String, _ how: String?) throws -> [String] {
        do {
            switch op {
            case "open":
                return try describe(try make(name), layout: !packed(name))
            case "incremental":
                let original = try make(name)
                let document = try PdfDocument.open(original)
                try SaveFixtures.edit(document)
                let saved = try document.saveIncremental()
                return exact.contains(name) ? lines(Array(saved[original.count...])) : try describe(saved, layout: false)
            case "rewrite":
                let document = try PdfDocument.open(try make(name))
                let saved = try document.saveRewrite(PdfSaveOptions(useObjectStreams: how == "packed", security: document.security))
                return exact.contains(name) && how == "plain" ? lines(saved) : try describe(saved, layout: false)
            default:
                return ["unknown op \(op)"]
            }
        } catch let failure as PdfReadException {
            return ["error \(problemName(failure.problem)) \(failure.message)"]
        }
    }

    private static func packed(_ name: String) -> Bool {
        name.hasPrefix("aes") || name.hasPrefix("object")
    }

    private static func problemName(_ problem: PdfReadProblem) -> String {
        switch problem {
        case .notPdf: return "NotPdf"
        case .damaged: return "Damaged"
        case .encrypted: return "Encrypted"
        case .passwordRequired: return "PasswordRequired"
        case .unsupported: return "Unsupported"
        case .certificateRequired: return "CertificateRequired"
        }
    }

    /// The bytes as escaped lines, one to each line of the file, with the second /ID string zeroed.
    private static func lines(_ file: [UInt8]) -> [String] {
        let masked = maskId(file)
        var result: [String] = []
        var start = 0
        for i in 0..<masked.count where masked[i] == 10 {
            result.append(Golden.escape(Array(masked[start..<i])))
            start = i + 1
        }
        if start < masked.count { result.append(Golden.escape(Array(masked[start...]))) }
        return result
    }

    private static func maskId(_ file: [UInt8]) -> [UInt8] {
        var copy = file
        let marker = "/ID [<".keywordBytes
        var i = 0
        while i + marker.count < copy.count {
            defer { i += 1 }
            if !copy.hasPattern(marker, at: i) { continue }
            var p = i + marker.count
            while p < copy.count && copy[p] != UInt8(ascii: ">") { p += 1 }
            if p + 2 >= copy.count || copy[p + 1] != UInt8(ascii: " ") || copy[p + 2] != UInt8(ascii: "<") { continue }
            p += 3
            while p < copy.count && copy[p] != UInt8(ascii: ">") {
                copy[p] = UInt8(ascii: "0")
                p += 1
            }
        }
        return copy
    }

    private static func describe(_ file: [UInt8], layout: Bool) throws -> [String] {
        let document: PdfDocument
        do {
            document = try PdfDocument.open(file)
        } catch let failure as PdfReadException {
            return ["error \(problemName(failure.problem)) \(failure.message)"]
        }
        var lines: [String] = []
        let id = document.id.first.map { Hex.string($0) } ?? "-"
        lines.append(layout ? "version \(document.version) encrypted \(yes(document.isEncrypted)) id \(id)"
                            : "version \(document.version) encrypted \(yes(document.isEncrypted))")
        let part = document.pdfAPart.map { String($0) } ?? ""
        lines.append("facts signed \(yes(document.isSigned)) certified \(yes(document.isCertified)) xfa \(yes(document.hasXfa)) "
                     + "tagged \(yes(document.isTagged)) linearized \(yes(document.isLinearized)) pdfa \(part)\(document.pdfAConformance ?? "")")
        if layout {
            lines.append("layout rebuilt \(yes(document.xrefRebuilt)) stream \(yes(document.xrefIsStream)) start \(document.startXref) "
                         + "next \(document.nextObjectNumber) length \(document.length)")
        } else {
            lines.append("layout rebuilt \(yes(document.xrefRebuilt)) stream \(yes(document.xrefIsStream)) next \(document.nextObjectNumber)")
        }
        lines.append("repairs \(document.repairs.count)")
        for repair in document.repairs { lines.append("repair \(repair)") }

        lines.append("pages \(document.pages.count)")
        for page in document.pages {
            lines.append("page \(page.index) ref \(page.reference.number) \(page.reference.generation) media \(box(page.mediaBox)) "
                         + "crop \(box(page.cropBox)) rotate \(page.rotate) unit \(PdfNumber(page.userUnit)) contents \(Golden.escape(page.contents()))")
        }

        for number in document.objectNumbers {
            var entry = ""
            if layout, let found = document.entries[number] {
                entry = " \(kindName(found.kind)) \(found.offset)"
            }
            let head = "obj \(number) gen \(document.generationOf(number))\(entry)"
            guard let value = document.get(number) else { continue }
            // The salts and keys of a new handler are random.
            if number == document.encryptNumber {
                lines.append("\(head) encryption dictionary")
                continue
            }
            if let stream = value as? PdfStream {
                let xref = document.name(stream.dictionary, "Type") == "XRef"
                let copy = PdfDictionary()
                // The second string of /ID is random, and /Prev is where a compressed section starts.
                for (key, item) in stream.dictionary.entries where key != "Length" && !(xref && (key == "ID" || key == "Prev")) {
                    copy.add(key, item)
                }
                if xref {
                    lines.append("\(head) \(copy)")
                    continue
                }
                let data: String
                do {
                    data = Golden.escape(try document.data(stream))
                } catch let failure as PdfReadException {
                    data = "error \(problemName(failure.problem))"
                }
                lines.append("\(head) \(copy) data \(data)")
            } else {
                lines.append("\(head) \(value)")
            }
        }
        return lines
    }

    private static func kindName(_ kind: PdfDocument.EntryKind) -> String {
        switch kind {
        case .free: return "Free"
        case .inUse: return "InUse"
        case .compressed: return "Compressed"
        case .new: return "New"
        }
    }

    private static func yes(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func box(_ rect: PdfRect) -> String {
        "[\(PdfNumber(rect.left)) \(PdfNumber(rect.bottom)) \(PdfNumber(rect.right)) \(PdfNumber(rect.top))]"
    }

    /// The file a name stands for. The C# builds the same ones with its TestPdf.
    static func make(_ name: String) throws -> [UInt8] {
        switch name {
        case "table", "stream", "hybrid", "objects", "aes128", "aes256", "aes256objects":
            return try SaveFixtures.make(name)
        case "simple2":
            return TestPdf.simple(2)
        case "junk-before":
            return TestPdf.latin("junk before\r\n") + TestPdf.simple(2)
        case "header-late":
            return [UInt8](repeating: 0, count: 2000) + TestPdf.simple()
        case "not-pdf":
            return TestPdf.latin("hello")
        case "no-startxref":
            return TestPdf.replace(TestPdf.simple(), "startxref", "startxxxxx")
        case "startxref-past-end":
            return TestPdf().obj(1, "<</Type /Catalog /Pages 2 0 R>>").obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
                .obj(3, "<</Type /Page /Parent 2 0 R>>").finish(startxref: "99999999")
        case "shifted":
            return TestPdf.withPages(2).finish(shift: 7)
        case "wrong-length":
            return TestPdf.withPages(1).stream(9, "", "twelve bytes", length: 3).stream(10, "", "ten bytes!", length: 500)
                .stream(11, "", "no length", length: -1).finish()
        case "no-endstream":
            return TestPdf.withPages(1).stream(9, "", "cut short", length: 400, endstream: false).finish()
        case "no-trailer":
            return TestPdf.withPages(2).finishWithoutXref()
        case "no-root":
            return TestPdf.withPages(2).finish("")
        case "truncated":
            let file = TestPdf.simple(3)
            return Array(file[0..<(file.count - 120)])
        case "no-catalog":
            return TestPdf().obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>").obj(3, "<</Type /Page /Parent 2 0 R>>")
                .obj(4, "<</Type /Page /Parent 2 0 R>>").finishWithoutXref()
        case "no-tree":
            return TestPdf().obj(3, "<</Type /Page /MediaBox [0 0 10 10]>>").obj(4, "<</Type /Page /MediaBox [0 0 20 20]>>").finishWithoutXref()
        case "later-definition":
            return TestPdf.withPages(1).obj(3, "<</Type /Page /Parent 2 0 R /Rotate 180 /Contents 4 0 R>>").finishWithoutXref()
        case "pdf-in-stream":
            return TestPdf.withPages(1).stream(8, "", "%PDF-1.4\n9 0 obj\n<</Type /Page /Rotate 90>>\nendobj\ntrailer\n<</Root 9 0 R>>\n").finishWithoutXref()
        case "prev-broken":
            let first = TestPdf.withPages(1).finish()
            let objectText = "3 0 obj\n<</Type /Page /Parent 2 0 R /Rotate 90 /Contents 4 0 R>>\nendobj\n"
            let text = objectText + "xref\n3 1\n" + String(format: "%010ld", first.count) + " 00000 n \n"
                + "trailer\n<</Size 5 /Root 1 0 R /Prev 5000000>>\nstartxref\n\(first.count + objectText.count)\n%%EOF\n"
            return first + TestPdf.latin(text)
        case "tree-ancestors":
            return TestPdf()
                .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                .obj(2, "<</Type /Pages /Kids [3 0 R] /Count 2 /MediaBox [0 0 100 200] /Rotate 90 /Resources <</Font <<>>>>>>")
                .obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /CropBox [10 10 60 60]>>")
                .obj(4, "<</Type /Page /Parent 3 0 R>>")
                .obj(5, "<</Type /Page /Parent 3 0 R /Rotate 270 /MediaBox [0 0 50 50] /Resources <</XObject <<>>>>>>")
                .finish()
        case "tree-cycle":
            return TestPdf()
                .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                .obj(2, "<</Type /Pages /Kids [3 0 R 2 0 R 4 0 R] /Count 2>>")
                .obj(3, "<</Type /Page /Parent 2 0 R>>")
                .obj(4, "<</Type /Pages /Parent 2 0 R /Kids [2 0 R 5 0 R]>>")
                .obj(5, "<</Type /Page /Parent 4 0 R>>")
                .finish()
        case "tree-junk":
            return TestPdf()
                .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                .obj(2, "<</Type /Pages /Kids [3 0 R 42 (text) null 77 0 R 6 0 R <</Type /Page>> 5 0 R 3 0 R] /Count 2>>")
                .obj(3, "<</Type /Page>>")
                .obj(5, "<</Type /Font /BaseFont /Helvetica>>")
                .obj(6, "[1 2 3]")
                .finish()
        case "tree-boxes":
            return TestPdf()
                .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
                .obj(3, "<</Type /Page /MediaBox [300 400 0 0] /TrimBox [5 5 15 25] /Rotate 450 /UserUnit 2>>")
                .obj(4, "<</Type /Page /MediaBox [0 0 0 0] /CropBox [1 2] /Rotate -90 /UserUnit -3 /BleedBox (x)>>")
                .finish()
        case "object-stream":
            let (pdf, xref) = ObjectStreamTests.objectStreamFile()
            return pdf.finishWithoutXref() + TestPdf.latin("startxref\n\(xref)\n%%EOF\n")
        case "object-stream-lost":
            let (pdf, _) = ObjectStreamTests.objectStreamFile()
            return pdf.finishWithoutXref() + TestPdf.latin("startxref\n12\n%%EOF\n")
        default:
            preconditionFailure(name)
        }
    }
}
