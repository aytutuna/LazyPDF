import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/ContentTagger.cs: plans the marked-content sequences of one page (ISO 32000-1
// 14.6). Text, images and forms go to the node that claimed them with an /MCID; paths, shadings and anything unclaimed
// become /Artifact. Operations are joined into one sequence only while nothing that would have to nest differently (a text
// object, a graphics state, other marked content) lies between them, so the result is well nested whatever the page does.

/// Text to put into a content stream at a byte position. At one position the order decides: closings (0) before openings (1).
struct ContentInsertion {
    let position: Int
    let order: Int
    let text: String
}

final class ContentTagger {
    private static let shows: Set<String> = ["Tj", "TJ", "'", "\""]
    private static let paths: Set<String> = ["m", "l", "c", "v", "y", "re", "h", "W", "W*", "f", "F", "f*", "B", "B*", "b", "b*", "S", "s", "n"]
    private static let breaks: Set<String> = ["BT", "ET", "q", "Q", "cm", "d0", "d1"]
    private static let singles: Set<String> = ["Do", "BI", "sh"]

    private let streams: [[ContentOperation]]
    private let claims: [Int: TagNode]
    private let newMcid: (TagNode) -> Int
    private var open: [Bool] = []
    private var skip = 0
    private var running = false
    private var target: TagNode?
    private var stream = 0, first = 0, last = 0

    init(_ streams: [[ContentOperation]], _ claims: [Int: TagNode], _ newMcid: @escaping (TagNode) -> Int) {
        self.streams = streams
        self.claims = claims
        self.newMcid = newMcid
        insertions = streams.map { _ in [] }
    }

    /// Per stream, what to insert.
    private(set) var insertions: [[ContentInsertion]]

    private(set) var artifacts = 0

    func run() {
        var global = 0
        for s in 0..<streams.count {
            close()
            for i in 0..<streams[s].count {
                handle(s, i, global)
                global += 1
            }
        }
        close()
    }

    private func handle(_ stream: Int, _ index: Int, _ global: Int) {
        let op = streams[stream][index]
        let name = op.operator
        if name == "BMC" || name == "BDC" {
            close()
            let foreign = isForeign(op)
            open.append(foreign)
            if foreign { skip += 1 }
        } else if name == "EMC" {
            close()
            if let foreign = open.popLast(), foreign { skip -= 1 }
        } else if Self.breaks.contains(name) {
            close()
        } else if skip > 0 {
            return
        } else if Self.shows.contains(name) {
            extend(stream, index, claims[global])
        } else if Self.paths.contains(name) {
            extend(stream, index, nil)
        } else if Self.singles.contains(name) {
            close()
            extend(stream, index, claims[global])
            close()
        }
    }

    // Content inside an /Artifact is somebody else's to describe. A sequence with an /MCID is not: with no tree
    // it belongs to nothing, and the new sequences are numbered past it.
    private func isForeign(_ op: ContentOperation) -> Bool {
        (op.operands.first as? PdfName)?.value == "Artifact"
    }

    /// The /MCID numbers the streams already carry. New sequences take the lowest numbers not in it, so a stale far-off number does not stretch the parent tree.
    static func usedMcids(_ streams: [[ContentOperation]], _ properties: (String) -> PdfDictionary?, _ document: PdfDocument) -> Set<Int> {
        var used = Set<Int>()
        for op in streams.joined() {
            if op.operator != "BDC" || op.operands.count < 2 { continue }
            let dictionary: PdfDictionary?
            if let d = op.operands[1] as? PdfDictionary {
                dictionary = d
            } else if let n = op.operands[1] as? PdfName {
                dictionary = properties(n.value)
            } else {
                dictionary = nil
            }
            if let id = document.integer(dictionary, "MCID"), id >= 0, id <= Int(Int32.max) { used.insert(id) }
        }
        return used
    }

    private func extend(_ stream: Int, _ index: Int, _ target: TagNode?) {
        if running && self.stream == stream && self.target === target {
            last = index
            return
        }
        close()
        (running, self.target, self.stream, first, last) = (true, target, stream, index, index)
    }

    private func close() {
        if !running { return }
        running = false
        let operations = streams[stream]
        let begin: String
        if let target {
            begin = "/\(target.type) <</MCID \(newMcid(target))>> BDC "
        } else {
            begin = "/Artifact BMC "
            artifacts += 1
        }
        insertions[stream].append(ContentInsertion(position: operations[first].start, order: 1, text: begin))
        insertions[stream].append(ContentInsertion(position: operations[last].end, order: 0, text: " EMC"))
    }

    static func apply(_ data: [UInt8], _ insertions: [ContentInsertion]) -> [UInt8] {
        // Equal positions and orders keep the order they were planned in.
        let ordered = insertions.enumerated().sorted { a, b in
            (a.element.position, a.element.order, a.offset) < (b.element.position, b.element.order, b.offset)
        }.map { $0.element }
        var output: [UInt8] = []
        output.reserveCapacity(data.count + insertions.count * 24)
        var at = 0
        for insertion in ordered {
            let position = min(max(insertion.position, at), data.count)
            output.append(contentsOf: data[at..<position])
            output.append(contentsOf: Array(insertion.text.utf8))
            at = position
        }
        output.append(contentsOf: data[at...])
        return output
    }
}
