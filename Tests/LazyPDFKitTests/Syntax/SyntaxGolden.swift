import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Syntax/SyntaxGolden.cs. One line of input is "<op> <escaped
// bytes>"; the result is what the lexer or the writer made of them, in text.
enum SyntaxGolden {
    static func lexer(_ input: String) -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? String(line)
            let data = Golden.unescape(space.map { String(line[line.index(after: $0)...]) } ?? "")
            output += "> \(line)\n< \(run(op, data))\n"
        }
        return output
    }

    static func numbers(_ input: String) -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            output += "\(line) -> \(PdfNumber(Double(line) ?? 0).text)\n"
        }
        return output
    }

    private static func run(_ op: String, _ data: [UInt8]) -> String {
        let lexer = PdfLexer(PdfArrayBytes(data))
        do {
            switch op {
            case "object": return describe(try lexer.readObject(), lexer)
            case "value": return describe(try lexer.readObject(allowStream: false), lexer)
            case "header":
                let header = try lexer.readObjectHeader()
                return "(\(header.number), \(header.generation)) pos=\(lexer.position)"
            case "keyword":
                return "\"\(Golden.escape(lexer.readKeyword()))\" pos=\(lexer.position)"
            case "unsigned":
                return "\(lexer.tryReadUnsigned().map { String($0) } ?? "none") pos=\(lexer.position)"
            case "string":
                let text = PdfString(bytes: data, isHex: false)
                let literal = text.description
                text.isHex = true
                return "\(literal) \(text)"
            case "name":
                return PdfName(Latin1.string(data)).description
            default:
                preconditionFailure("No op \"\(op)\".")
            }
        } catch let error as PdfReadException {
            return "error \(error.problem): \(Golden.escape(error.message))"
        } catch {
            preconditionFailure("\(error)")
        }
    }

    private static func describe(_ value: PdfObject, _ lexer: PdfLexer) -> String {
        let kind = String(describing: type(of: value))
        let written: String
        switch value {
        case let number as PdfNumber: written = "\(number.text) integer=\(number.integer.map { String($0) } ?? "none")"
        case let stream as PdfStream: written = "\(stream.dictionary) data@\(stream.dataOffset)"
        default: written = value.description
        }
        return "\(kind) \(Golden.escape(written)) pos=\(lexer.position)"
    }
}
