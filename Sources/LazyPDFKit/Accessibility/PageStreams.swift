import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PageStreams.cs: a page's content streams parsed one by one, with operations
// numbered across them as the interpreter numbers the page's joined content. Nil from `load` when a stream does not parse
// or an operator stands in another stream than its operands, where one stream's operations cannot be cut alone.

final class PageStreams {
    private static let content: Set<String> = ["Tj", "TJ", "'", "\"", "Do", "BI"]

    private let document: PdfDocument
    private var first: [Int] = []

    let page: PdfPage
    private(set) var streams: [PdfStream] = []
    private(set) var data: [[UInt8]] = []
    private(set) var parsed: [[ContentOperation]] = []

    /// Another page draws one of these streams, so rewriting it would change that page too.
    private(set) var isShared = false

    private(set) var count = 0

    private init(_ document: PdfDocument, _ page: PdfPage) {
        self.document = document
        self.page = page
    }

    static func load(_ document: PdfDocument, _ page: PdfPage) -> PageStreams? {
        let result = PageStreams(document, page)
        do {
            for stream in TagSession.streams(document, page) {
                result.streams.append(stream)
                result.data.append(try document.data(stream))
                result.first.append(result.count)
                result.parsed.append(ContentParser.parse(result.data[result.data.count - 1]))
                result.count += result.parsed[result.parsed.count - 1].count
            }
        } catch {
            return nil
        }
        let joined = ContentParser.parse(page.contents())
        if !result.parsed.joined().elementsEqual(joined, by: { $0.operator == $1.operator && $0.operands.count == $1.operands.count }) { return nil }
        let uses = TagSession.sharedStreams(document)
        result.isShared = result.streams.contains { (uses[ObjectIdentifier($0)] ?? 0) > 1 }
        return result
    }

    static func isContent(_ op: ContentOperation) -> Bool { content.contains(op.operator) }

    func at(_ global: Int) -> (stream: Int, operation: ContentOperation) {
        var stream = first.count - 1
        while first[stream] > global { stream -= 1 }
        return (stream, parsed[stream][global - first[stream]])
    }

    func properties() -> (String) -> PdfDictionary? {
        let properties = document.dict(page.resources, "Properties")
        return { [document] in document.dict(properties, $0) }
    }

    func newEdits() -> [[ContentInsertion]] { streams.map { _ in [] } }

    func save(_ edits: [[ContentInsertion]]) {
        for s in 0..<streams.count where !edits[s].isEmpty {
            streams[s].data = PdfFilterEncoders.flate(ContentTagger.apply(data[s], edits[s]))
            streams[s].dictionary["Filter"] = PdfName("FlateDecode")
            streams[s].dictionary.remove("DecodeParms")
        }
    }
}

/// A marked-content sequence of a page, BMC or BDC to its EMC, with the content operations directly inside it.
final class MarkedSequence {
    /// Operation number of the BMC or BDC; -1 for the pseudo sequence that holds the page level.
    let begin: Int
    let mcid: Int?
    let artifact: Bool
    private(set) weak var parent: MarkedSequence?
    var content: [Int] = []
    var children: [MarkedSequence] = []

    init(begin: Int = -1, mcid: Int? = nil, artifact: Bool = false, parent: MarkedSequence? = nil) {
        self.begin = begin
        self.mcid = mcid
        self.artifact = artifact
        self.parent = parent
    }

    /// A sequence that already says what its content is.
    var isClaimed: Bool { mcid != nil || artifact }

    func descendants() -> [MarkedSequence] {
        children.flatMap { [$0] + $0.descendants() }
    }

    /// Every content operation inside, nested sequences included.
    func allContent() -> [Int] {
        content + children.flatMap { $0.allContent() }
    }

    /// The sequences of the page and, in the returned pseudo sequence, what sits outside all of them. An EMC with nothing open is dropped and a BDC never closed runs to the end.
    static func scan(_ page: PageStreams, _ document: PdfDocument) -> MarkedSequence {
        let properties = page.properties()
        let top = MarkedSequence()
        var current = top
        var open: [MarkedSequence] = []
        var global = 0
        for operations in page.parsed {
            for op in operations {
                if op.operator == "BMC" || op.operator == "BDC" {
                    var mcid: Int?
                    if op.operator == "BDC" && op.operands.count > 1 {
                        let dictionary: PdfDictionary?
                        if let d = op.operands[1] as? PdfDictionary {
                            dictionary = d
                        } else if let n = op.operands[1] as? PdfName {
                            dictionary = properties(n.value)
                        } else {
                            dictionary = nil
                        }
                        if let id = document.integer(dictionary, "MCID"), id >= 0, id <= Int(Int32.max) { mcid = id }
                    }
                    let sequence = MarkedSequence(begin: global, mcid: mcid, artifact: (op.operands.first as? PdfName)?.value == "Artifact", parent: current)
                    current.children.append(sequence)
                    open.append(current)
                    current = sequence
                } else if op.operator == "EMC" {
                    if let up = open.popLast() { current = up }
                } else if PageStreams.isContent(op) {
                    current.content.append(global)
                }
                global += 1
            }
        }
        return top
    }
}
