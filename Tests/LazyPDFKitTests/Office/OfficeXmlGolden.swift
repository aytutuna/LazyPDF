import Foundation
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/XmlTreeGolden.cs. The input format is at the top of xml-input.txt.
enum OfficeXmlGolden {
    static func run(_ input: String) -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix("# ") { continue }
            output += "> \(line)\n"
            let space = line.firstIndex(of: " ")!
            let op = line[..<space]
            var rest = String(line[line.index(after: space)...])
            var limits = OfficeXmlLimits.standard
            if op == "limits" {
                let w = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                limits = OfficeXmlLimits(maxDepth: Int(w[0])!, maxElements: Int(w[1])!, maxAttributes: Int(w[2])!)
                rest = String(w[3])
            }
            do {
                dump(try OfficeXml.parse(Golden.unescape(rest), limits), 0, &output)
            } catch let e as PdfReadException {
                output += "< error \(e.problem == .damaged ? "Damaged" : "Unsupported")\n"
            } catch {
                output += "< error \(error)\n"
            }
        }
        return output
    }

    private static func dump(_ e: OfficeXmlElement, _ depth: Int, _ o: inout String) {
        let pad = String(repeating: " ", count: depth * 2)
        o += "< \(pad)E {\(e.uri)}\(e.name)\n"
        for a in e.attributes { o += "< \(pad)  A {\(a.uri)}\(a.name)=\"\(esc(a.value))\"\n" }
        for n in e.children {
            switch n {
            case .element(let child): dump(child, depth + 1, &o)
            case .text(let t): o += "< \(pad)  T \"\(esc(t))\"\n"
            }
        }
    }

    private static func esc(_ text: String) -> String {
        var sb = ""
        for c in text.utf16 {
            switch c {
            case 0x5C: sb += "\\\\"
            case 0x22: sb += "\\\""
            case 0x0A: sb += "\\n"
            case 0x0D: sb += "\\r"
            case 0x09: sb += "\\t"
            default:
                if c < 0x20 || c >= 0x7F {
                    let hex = String(c, radix: 16, uppercase: true)
                    sb += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    sb += String(UnicodeScalar(UInt8(c)))
                }
            }
        }
        return sb
    }
}
