import Foundation

// Twin of windows/LazyPDF.Core/Optimize/SanitizeLayers.cs: layers that are off in the default view. Their content is
// cut out of the streams, found by the marked content (/OC BDC ... EMC) and the /OC of images and forms, and then the
// groups themselves are removed from the file.

final class SanitizeLayers {
    private let document: PdfDocument
    private var visibility: LayerVisibility?
    private var page: PdfPage?

    // Operation ranges to cut, by the page or form they belong to: (first operation, last operation or -1 for "the matching EMC").
    private var cuts: [ObjectIdentifier: [(from: Int, to: Int)]] = [:]
    private var owners: [PdfObject] = []

    init(_ document: PdfDocument) {
        self.document = document
    }

    private final class Finder: ContentVisitor {
        unowned let owner: SanitizeLayers

        init(_ owner: SanitizeLayers) {
            self.owner = owner
            super.init()
        }

        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
            if let group = marked.optionalContent, owner.isHidden(group) {
                owner.cut(context.forms.last, context.operatorIndex, -1)
            }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if let group = image.optionalContent, owner.isHidden(group) {
                owner.cut(context.forms.last, context.operatorIndex, context.operatorIndex)
            }
        }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) {
            if !form.isPattern, let group = form.optionalContent, owner.isHidden(group) {
                owner.cut(context.forms.count < 2 ? nil : context.forms[context.forms.count - 2], context.operatorIndex, context.operatorIndex)
            }
        }
    }

    private func isHidden(_ group: PdfDictionary) -> Bool { visibility?.isHidden(group) ?? false }

    private func cut(_ form: PdfStream?, _ from: Int, _ to: Int) {
        let key: PdfObject
        if let form {
            key = form
        } else if let own = page?.dictionary {
            key = own
        } else {
            return
        }
        let id = ObjectIdentifier(key)
        if cuts[id] == nil {
            cuts[id] = []
            owners.append(key)
        }
        cuts[id]?.append((from, to))
    }

    /// Returns the number of hidden layers; with `remove` their content and the groups go.
    func run(_ remove: Bool) throws -> Int {
        let hiddenLayers = PdfLayers.read(document).layers.filter { !$0.isOn }
        if hiddenLayers.isEmpty || !remove { return hiddenLayers.count }
        let hidden = LayerVisibility(document)
        visibility = hidden

        let finder = Finder(self)
        let interpreter = ContentInterpreter(document)
        for page in document.pages {
            self.page = page
            interpreter.run(page, finder)
            for (form, matrix) in PageAppearances.of(document, page) { interpreter.run(form, finder, matrix) }
        }
        for owner in owners {
            guard let ranges = cuts[ObjectIdentifier(owner)] else { continue }
            if let pageDictionary = owner as? PdfDictionary {
                if let target = document.pages.first(where: { $0.dictionary === pageDictionary }) { try cutPage(target, ranges) }
            } else if let form = owner as? PdfStream {
                try cutForm(form, ranges)
            }
        }
        // The forms and pictures whose Do went are still named in the resources.
        if !cuts.isEmpty { _ = OptimizeResources(document).run() }
        SanitizeData.removeAnnotations(document) { a in
            if let group = document.dict(a, "OC") { return hidden.isHidden(group) }
            return false
        }
        PdfGraph.detach(document, Set(hiddenLayers.map { $0.reference.number }))
        if let properties = document.dict(document.catalog, "OCProperties"), (document.array(properties, "OCGs")?.items.count ?? 0) == 0 {
            document.catalog.remove("OCProperties")
        }
        return hiddenLayers.count
    }

    private func cutPage(_ page: PdfPage, _ ranges: [(from: Int, to: Int)]) throws {
        let data = page.contents()
        let stream = PdfStream(PdfDictionary(), data: [])
        PdfGraph.setData(stream, Self.remove(data, ranges))
        page.dictionary["Contents"] = try document.add(stream)
    }

    private func cutForm(_ form: PdfStream, _ ranges: [(from: Int, to: Int)]) throws {
        PdfGraph.setData(form, Self.remove(try document.data(form), ranges))
    }

    private static func remove(_ data: [UInt8], _ ranges: [(from: Int, to: Int)]) -> [UInt8] {
        let operations = ContentParser.parse(data)
        var cut: [(start: Int, end: Int)] = []
        for (from, to) in ranges {
            if from < 0 || from >= operations.count { continue }
            var last = to
            if to < 0 {
                var depth = 0
                last = operations.count - 1
                for i in from..<operations.count {
                    let name = operations[i].operator
                    if name == "BMC" || name == "BDC" {
                        depth += 1
                    } else if name == "EMC" {
                        depth -= 1
                        if depth == 0 {
                            last = i
                            break
                        }
                    }
                }
            }
            if last < 0 || last >= operations.count { continue }
            cut.append((operations[from].start, operations[last].end))
        }
        cut.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var output: [UInt8] = []
        var position = 0
        for (start, end) in cut {
            if end <= position { continue }
            if start > position { output += data[position..<start] }
            position = end
        }
        output += data[position...]
        return output
    }
}
