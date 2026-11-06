import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagSession.cs: the tree being built while the pages are tagged one after the
// other: headings are levelled across pages, so state is carried from page to page.

final class TagSession {
    private static let maxHeadingLevel = 6

    private let document: PdfDocument
    private let tree: StructureTree
    private let root = StructElement("Document")
    private var levels: [HeadingLook: Int] = [:]
    private var figures: [(page: Int, element: StructElement)] = []
    private var slots = 0
    private var level = 0, headings = 0, paragraphs = 0, lists = 0, tables = 0, artifacts = 0

    init(_ document: PdfDocument, _ layouts: [TagPage?]) throws {
        self.document = document
        tree = StructureTree.create(document)
        try tree.add(nil, root)

        // Biggest or boldest look is H1; looks past the sixth share the last level.
        var looks = Set<HeadingLook>()
        for layout in layouts {
            for node in layout?.nodes ?? [] {
                for inner in Self.all(node) {
                    if let look = inner.heading { looks.insert(look) }
                }
            }
        }
        let ordered = looks.sorted { $0.size != $1.size ? $0.size > $1.size : ($0.bold && !$1.bold) }
        for (i, look) in ordered.enumerated() { levels[look] = min(i + 1, Self.maxHeadingLevel) }
    }

    private(set) var skipped = 0

    static func sharedStreams(_ document: PdfDocument) -> [ObjectIdentifier: Int] {
        var uses: [ObjectIdentifier: Int] = [:]
        for page in document.pages {
            for stream in streams(document, page) { uses[ObjectIdentifier(stream), default: 0] += 1 }
        }
        return uses
    }

    static func streams(_ document: PdfDocument, _ page: PdfPage) -> [PdfStream] {
        let contents = document.resolve(page.dictionary["Contents"])
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        return items.compactMap { document.resolve($0) as? PdfStream }
    }

    func write() throws {
        try tree.write(document)
    }

    func result(_ pages: Int) -> AutoTagResult {
        AutoTagResult(false, pages - skipped, skipped, headings, paragraphs, lists, tables, figures.count, artifacts,
                      figures.compactMap { figure in figure.element.reference.map { TaggedFigure(figure.page, $0) } })
    }

    private static func all(_ node: TagNode) -> [TagNode] {
        [node] + node.children.flatMap { all($0) }
    }

    private static func leaves(_ node: TagNode) -> [TagNode] {
        node.children.isEmpty ? [node] : node.children.flatMap { leaves($0) }
    }

    /// Rewrites the page's content and adds its elements. A page whose content cannot be read or does not parse the way the layout saw it is skipped untouched.
    func tag(_ page: PdfPage, _ layout: TagPage?) throws {
        guard let layout, try tryTag(page, layout) else {
            skipped += 1
            return
        }
    }

    private func tryTag(_ page: PdfPage, _ layout: TagPage) throws -> Bool {
        let own = Self.streams(document, page)
        var streams: [PdfStream]? = own
        var data: [[UInt8]] = []
        var parsed: [[ContentOperation]] = []
        do {
            for stream in own {
                data.append(try document.data(stream))
                parsed.append(ContentParser.parse(data[data.count - 1]))
            }
        } catch is PdfReadException {
            return false
        }

        // An operator may stand in a later stream than its operands (7.8.2); only then are the streams joined into one.
        let joinedData = page.contents()
        let joined = ContentParser.parse(joinedData)
        let same = parsed.joined().elementsEqual(joined) { $0.operator == $1.operator && $0.operands.count == $1.operands.count }
        if !same {
            streams = nil
            data = [joinedData]
            parsed = [joined]
        }

        var level = self.level
        for node in layout.nodes { createElements(node, page.index, &level) }

        // Text claims an operation before a figure does: a form that draws both is described by its words.
        var claims: [Int: TagNode] = [:]
        let leaves = layout.nodes.flatMap { Self.leaves($0) }
        for leaf in leaves.filter({ $0.type != "Figure" }) + leaves.filter({ $0.type == "Figure" }) {
            for op in leaf.operations where claims[op] == nil { claims[op] = leaf }
        }

        let properties = document.dict(page.resources, "Properties")
        let used = ContentTagger.usedMcids(parsed, { self.document.dict(properties, $0) }, document)
        var numbered: [(node: TagNode, mcid: Int)] = []
        var next = 0
        let planner = ContentTagger(parsed, claims) { node in
            while used.contains(next) { next += 1 }
            numbered.append((node, next))
            next += 1
            return next - 1
        }
        planner.run()

        // The parent tree keeps an array up to the highest number of each page; refusing here leaves the page as it was.
        let highest = numbered.map { $0.mcid }.max() ?? -1
        if highest > StructureTree.maxMcid || slots + highest + 1 > StructureTree.maxParentSlots { return false }
        slots += highest + 1
        self.level = level
        for item in numbered {
            if let element = item.node.element { try tree.add(element, StructContent(page.index, item.mcid)) }
        }

        artifacts += planner.artifacts
        if let streams {
            for (s, stream) in streams.enumerated() where !planner.insertions[s].isEmpty {
                stream.data = PdfFilterEncoders.flate(ContentTagger.apply(data[s], planner.insertions[s]))
                stream.dictionary["Filter"] = PdfName("FlateDecode")
                stream.dictionary.remove("DecodeParms")
            }
        } else {
            let dictionary = PdfDictionary()
            dictionary["Filter"] = PdfName("FlateDecode")
            let merged = PdfStream(dictionary, data: PdfFilterEncoders.flate(ContentTagger.apply(data[0], planner.insertions[0])))
            page.dictionary["Contents"] = try document.add(merged)
        }
        page.dictionary["Tabs"] = PdfName("S")

        for node in layout.nodes { try attach(root, node, page.index) }
        try addAnnotations(page, layout)
        return true
    }

    private func createElements(_ node: TagNode, _ page: Int, _ previousLevel: inout Int) {
        if let look = node.heading {
            previousLevel = min(levels[look] ?? Self.maxHeadingLevel, previousLevel + 1)
            node.type = "H" + String(previousLevel)
        }
        let element = StructElement(node.type)
        element.pageIndex = page
        node.element = element
        if node.type == "TH" {
            let attributes = PdfDictionary()
            attributes["O"] = PdfName("Table")
            attributes["Scope"] = PdfName("Column")
            element.dictionary["A"] = attributes
        }
        for child in node.children { createElements(child, page, &previousLevel) }
    }

    private static func hasContent(_ node: TagNode) -> Bool {
        (node.element?.kids.contains { $0 is StructContent } ?? false) || node.children.contains { hasContent($0) }
    }

    private func attach(_ parent: StructElement, _ node: TagNode, _ page: Int) throws {
        guard Self.hasContent(node), let element = node.element else { return }
        try tree.add(parent, element)
        for child in node.children { try attach(element, child, page) }
        switch node.type {
        case "P": paragraphs += 1
        case "L": lists += 1
        case "Table": tables += 1
        case "Figure": figures.append((page, element))
        default:
            if node.heading != nil { headings += 1 }
        }
    }

    private func addAnnotations(_ page: PdfPage, _ layout: TagPage) throws {
        for annotation in layout.annotations {
            let type = annotation.subtype == "Link" ? "Link" : annotation.subtype == "Widget" ? "Form" : "Annot"
            let element = StructElement(type)
            element.pageIndex = page.index
            try tree.add(root, element)
            try tree.add(element, StructObject(page.index, annotation.reference))

            guard let dictionary = document.resolve(annotation.reference) as? PdfDictionary else { continue }
            let contents = PdfText.read(document, dictionary, "Contents") ?? ""
            if annotation.subtype == "Link" {
                var alt = annotation.text.isEmpty ? contents : annotation.text
                if alt.isEmpty, let action = document.dict(dictionary, "A"), let uri = document.resolve(action["URI"]) as? PdfString {
                    alt = PdfText.decode(uri.bytes)
                }
                if !alt.isEmpty { element.alt = alt }
                if contents.isEmpty && !alt.isEmpty { dictionary["Contents"] = PdfText.toObject(alt) }
            } else if !contents.isEmpty {
                element.alt = contents
            }
        }
    }
}
