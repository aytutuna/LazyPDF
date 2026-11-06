import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Optimize/OptimizeGolden.cs. One line of input is "<op> <argument>": linearize
// <pages>, audit dirty, scan dirty, sanitize dirty, optimize <preset>. A linearized file is written byte for byte;
// the rest print counts, which do not hang on deflate output.
enum OptimizeGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let words = line.components(separatedBy: " ")
            output += "> \(line)\n"
            for result in try op(words[0], words[1]) { output += "< \(result)\n" }
        }
        return output
    }

    private static func findings(_ list: [SanitizeFinding]) -> String {
        list.map { "\(Self.name($0.item))=\($0.count)" }.joined(separator: " ")
    }

    // The C# prints enum names with a capital first letter.
    private static func name(_ item: SanitizeItem) -> String { capital("\(item)") }

    private static func capital(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    private static func op(_ op: String, _ argument: String) throws -> [String] {
        switch op {
        case "linearize":
            let source = try PdfDocument.open(LinearizerKit.make(Int(argument) ?? 1))
            // The second string of /ID is random; it is set to zeros.
            let text = Latin1.string(try source.saveLinearized())
            let zeroed = text.replacingOccurrences(of: #"(/ID \[<[0-9A-F]{32}> )<[0-9A-F]{32}>"#, with: "$1<" + String(repeating: "0", count: 32) + ">", options: .regularExpression)
            return [Golden.escape(zeroed)]
        case "audit":
            let audit = PdfOptimizer(try PdfDocument.open(try SanitizeKit.dirty())).audit()
            return ["size \(audit.fileSize)"] + SpaceKind.allCases.map { "\(capital("\($0)")) \(audit.of($0))" }
        case "scan":
            return [findings(try PdfSanitizer(try PdfDocument.open(try SanitizeKit.dirty())).scan())]
        case "sanitize":
            let result = try PdfSanitizer(try PdfDocument.open(try SanitizeKit.dirty())).run(SanitizeOptions())
            return ["removed \(findings(result.removed))", "kept \(findings(result.kept))"]
        default:
            let preset: OptimizePreset = argument == "small" ? .small : argument == "balanced" ? .balanced : .highQuality
            let result = try PdfOptimizer(try PdfDocument.open(try SanitizeKit.dirty())).run(OptimizeOptions.for(preset))
            return [result.steps.map { "\(capital("\($0.kind)"))=\($0.count)" }.joined(separator: " "), "notes \(result.notes.count)"]
        }
    }
}
