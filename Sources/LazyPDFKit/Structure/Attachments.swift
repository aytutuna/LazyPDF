import Foundation

// Twin of windows/LazyPDF.Core/Structure/Attachments.cs: a file inside the PDF (ISO 32000-1 7.11.4), and the portfolio
// that holds files as its documents (12.3.5).
//
// Unique takes the name apart as Path.GetFileNameWithoutExtension and GetExtension do on Windows: both slashes end a
// directory part, which a numbered name then leaves out, and so does a drive letter with its colon; no other colon does.

/// A file inside the PDF: an entry of the /EmbeddedFiles name tree (`pageIndex` nil) or a FileAttachment annotation on that
/// page. Sizes are in bytes, `size` as the file says (uncompressed) and `storedSize` of the stream as stored; `checkSum` is
/// the MD5 as hex.
public struct PdfAttachment {
    public var name: String
    public var fileName: String
    public var description: String?
    public var mimeType: String?
    public var size: Int?
    public var storedSize: Int?
    public var created: DateTimeOffset?
    public var modified: DateTimeOffset?
    public var checkSum: String?
    public var pageIndex: Int?
    public var annotation: PdfReference?

    var spec: PdfObject?
    var key: String?

    public init(_ name: String, _ fileName: String, _ description: String?, _ mimeType: String?, _ size: Int?, _ storedSize: Int?,
                _ created: DateTimeOffset?, _ modified: DateTimeOffset?, _ checkSum: String?, _ pageIndex: Int?, _ annotation: PdfReference?) {
        self.name = name
        self.fileName = fileName
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.storedSize = storedSize
        self.created = created
        self.modified = modified
        self.checkSum = checkSum
        self.pageIndex = pageIndex
        self.annotation = annotation
    }
}

public enum PdfAttachments {
    private static let maxAnnotations = 50_000
    private static let streamKeys = ["UF", "F", "DOS", "Mac", "Unix"]

    /// The embedded files of the tree, then those of the pages' attachment annotations. A file specification with no
    /// embedded stream is left out.
    public static func list(_ document: PdfDocument) -> [PdfAttachment] {
        var list: [PdfAttachment] = []
        let tree = document.dict(document.dict(document.catalog, "Names"), "EmbeddedFiles")
        for (key, value) in PdfNameTree.read(document, tree) {
            if var found = describe(document, PdfNameTree.textOf(key), value, nil, nil, nil) {
                found.key = key
                list.append(found)
            }
        }
        var annotations = 0
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                annotations += 1
                if annotations > maxAnnotations { return list }
                guard let annot = document.resolve(item) as? PdfDictionary, document.name(annot, "Subtype") == "FileAttachment" else { continue }
                let note = PdfText.read(document, annot, "Contents")
                if var found = describe(document, "", annot["FS"], page.index, item as? PdfReference, note) {
                    found.name = found.fileName
                    list.append(found)
                }
            }
        }
        return list
    }

    static func streamOf(_ document: PdfDocument, _ attachment: PdfAttachment) -> PdfStream? {
        embeddedStream(document, document.resolve(attachment.spec) as? PdfDictionary)
    }

    /// The file's bytes, decoded.
    public static func extract(_ document: PdfDocument, _ attachment: PdfAttachment) throws -> [UInt8] {
        guard let stream = embeddedStream(document, document.resolve(attachment.spec) as? PdfDictionary) else {
            throw InvalidOperationException("The attachment is no longer in the document.")
        }
        return try document.data(stream)
    }

    /// Adds a file to the /EmbeddedFiles tree. A name the tree has already gets " (2)", " (3)"... before its extension.
    /// Dates are given, not read from a clock; they are left out when nil.
    @discardableResult
    public static func add(_ document: PdfDocument, _ name: String, _ data: [UInt8], mimeType: String? = nil, description: String? = nil,
                           created: DateTimeOffset? = nil, modified: DateTimeOffset? = nil) throws -> PdfAttachment {
        let tree = document.dict(document.dict(document.catalog, "Names"), "EmbeddedFiles")
        var entries = PdfNameTree.read(document, tree)
        let unique = Self.unique(name, Set(entries.map { PdfNameTree.textOf($0.key) }))

        let parameters = PdfDictionary()
        parameters["Size"] = PdfNumber(data.count)
        if let c = created { parameters["CreationDate"] = PdfText.toObject(PdfDate.format(c)) }
        if let m = modified { parameters["ModDate"] = PdfText.toObject(PdfDate.format(m)) }
        parameters["CheckSum"] = PdfString(bytes: Md5.hash(data), isHex: true)
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("EmbeddedFile")
        if let mimeType { dictionary["Subtype"] = PdfName(mimeType) }
        dictionary["Params"] = parameters
        var stored = data
        if data.count > 64 {
            let packed = PdfFilterEncoders.flate(data)
            if packed.count < data.count {
                stored = packed
                dictionary["Filter"] = PdfName("FlateDecode")
            }
        }
        let stream = try document.add(PdfStream(dictionary, data: stored))

        let spec = PdfDictionary()
        spec["Type"] = PdfName("Filespec")
        spec["F"] = PdfText.toFileName(unique)
        spec["UF"] = PdfText.toObject(unique)
        let files = PdfDictionary()
        files["F"] = stream
        files["UF"] = stream
        spec["EF"] = files
        if let description, !description.isEmpty { spec["Desc"] = PdfText.toObject(description) }
        let specRef = try document.add(spec)

        entries.append((PdfNameTree.keyOf(unique), specRef))
        try writeTree(document, tree, entries)
        guard var added = describe(document, unique, specRef, nil, nil, nil) else {
            preconditionFailure("The attachment just added has no embedded stream.")
        }
        added.key = PdfNameTree.keyOf(unique)
        return added
    }

    /// Takes the file out and frees its objects: an entry of the tree by name, an annotation by its reference. False when
    /// it is not there.
    @discardableResult
    public static func remove(_ document: PdfDocument, _ attachment: PdfAttachment) throws -> Bool {
        if let annotation = attachment.annotation {
            var page: PdfPage?
            if let i = attachment.pageIndex, i >= 0, i < document.pages.count { page = document.pages[i] }
            guard let page, let annots = document.array(page.dictionary, "Annots") else { return false }
            if !annots.items.contains(where: { ($0 as? PdfReference)?.number == annotation.number }) { return false }
            // The popup and replies go with it, as when the annotation is deleted any other way.
            if let d = document.resolve(annotation) as? PdfDictionary, let parsed = PdfAnnotations.parse(document, d, annotation, page.index) {
                PdfAnnotationWriter(document).delete(parsed)
            } else {
                annots.items.removeAll { ($0 as? PdfReference)?.number == annotation.number }
                document.delete(annotation.number)
            }
            if !inUse(document, attachment.spec) { freeSpec(document, attachment.spec) }
            return true
        }
        let tree = document.dict(document.dict(document.catalog, "Names"), "EmbeddedFiles")
        var entries = PdfNameTree.read(document, tree)
        let key = attachment.key ?? PdfNameTree.keyOf(attachment.name)
        guard let at = entries.firstIndex(where: { $0.key == key }) else { return false }
        let spec = entries[at].value
        entries.remove(at: at)
        if !inUse(document, spec) && !entries.contains(where: { sameObject(document, $0.value, spec) }) { freeSpec(document, spec) }
        if entries.isEmpty, let names = document.dict(document.catalog, "Names") {
            _ = try PdfNameTree.write(document, tree, entries)
            if let root = names["EmbeddedFiles"] as? PdfReference { document.delete(root.number) }
            names.remove("EmbeddedFiles")
        } else {
            try writeTree(document, tree, entries)
        }
        return true
    }

    private static func describe(_ document: PdfDocument, _ name: String, _ value: PdfObject?, _ page: Int?, _ annotation: PdfReference?, _ note: String?) -> PdfAttachment? {
        guard let spec = document.resolve(value) as? PdfDictionary, let stream = embeddedStream(document, spec) else { return nil }
        let parameters = document.dict(stream.dictionary, "Params")
        let fileName = PdfActions.fileName(document, spec) ?? name
        var checksum: String?
        if let sum = document.resolve(parameters?["CheckSum"]) as? PdfString, !sum.bytes.isEmpty {
            checksum = sum.bytes.map { String(format: "%02X", $0) }.joined()
        }
        var found = PdfAttachment(
            name.isEmpty ? fileName : name, fileName, PdfText.read(document, spec, "Desc") ?? note,
            document.name(stream.dictionary, "Subtype"), document.integer(parameters, "Size"),
            stream.data?.count ?? document.integer(stream.dictionary, "Length"),
            PdfDate.parse(PdfText.read(document, parameters, "CreationDate")), PdfDate.parse(PdfText.read(document, parameters, "ModDate")),
            checksum, page, annotation)
        found.spec = value
        return found
    }

    private static func embeddedStream(_ document: PdfDocument, _ spec: PdfDictionary?) -> PdfStream? {
        guard let files = document.dict(spec, "EF") else { return nil }
        for key in streamKeys {
            if let stream = document.stream(files, key) { return stream }
        }
        return nil
    }

    // A page copied with its file attachment shares the file specification with the original.
    private static func inUse(_ document: PdfDocument, _ spec: PdfObject?) -> Bool {
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                if let d = document.resolve(item) as? PdfDictionary, sameObject(document, d["FS"], spec) { return true }
            }
        }
        return false
    }

    private static func sameObject(_ document: PdfDocument, _ a: PdfObject?, _ b: PdfObject?) -> Bool {
        if let x = a as? PdfReference, let y = b as? PdfReference { return x.number == y.number }
        guard let resolved = document.resolve(a) else { return false }
        return resolved === document.resolve(b)
    }

    private static func freeSpec(_ document: PdfDocument, _ value: PdfObject?) {
        if let spec = document.resolve(value) as? PdfDictionary, let files = document.dict(spec, "EF") {
            for entry in files.entries {
                if let stream = entry.value as? PdfReference { document.delete(stream.number) }
            }
        }
        if let reference = value as? PdfReference { document.delete(reference.number) }
    }

    private static func writeTree(_ document: PdfDocument, _ tree: PdfDictionary?, _ entries: [(key: String, value: PdfObject)]) throws {
        let root = try PdfNameTree.write(document, tree, entries)
        if tree == nil { PdfNames.ensure(document)["EmbeddedFiles"] = try document.add(root) }
    }

    private static func unique(_ name: String, _ taken: Set<String>) -> String {
        if !taken.contains(name) { return name }
        let (stem, fileExtension) = parts(name)
        var n = 2
        while true {
            let candidate = "\(stem) (\(n))\(fileExtension)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // Path.GetFileNameWithoutExtension and Path.GetExtension as .NET reads them on Windows: a file name starts after the
    // last slash or backslash, or after a drive letter and its colon; any other colon belongs to the name.
    private static func parts(_ name: String) -> (stem: String, ext: String) {
        let scalars = Array(name.unicodeScalars)
        var start = 0
        if scalars.count >= 2, scalars[1] == ":", let drive = scalars.first, drive.isASCII, drive.properties.isAlphabetic { start = 2 }
        for (i, c) in scalars.enumerated() where c == "/" || c == "\\" { start = i + 1 }
        let file = Array(scalars[start...])
        guard let dot = file.lastIndex(of: ".") else { return (String(String.UnicodeScalarView(file)), "") }
        let stem = String(String.UnicodeScalarView(file[..<dot]))
        let tail = dot == file.count - 1 ? "" : String(String.UnicodeScalarView(file[dot...]))
        return (stem, tail)
    }
}

/// One column of a portfolio's detail view (ISO 32000-1 12.3.5, table 156).
public struct PortfolioField {
    public let key: String
    public let label: String
    public let type: String
    public let order: Int
    public let visible: Bool
    public let editable: Bool

    public init(_ key: String, _ label: String, _ type: String, _ order: Int, _ visible: Bool, _ editable: Bool) {
        self.key = key
        self.label = label
        self.type = type
        self.order = order
        self.visible = visible
        self.editable = editable
    }
}

/// A PDF portfolio: the /Collection of the catalog. `view` is "D" (details), "T" (tiles) or "H" (hidden).
public struct PdfPortfolio {
    public let view: String
    public let initialDocument: String?
    public let fields: [PortfolioField]

    public init(_ view: String, _ initialDocument: String?, _ fields: [PortfolioField]) {
        self.view = view
        self.initialDocument = initialDocument
        self.fields = fields
    }

    /// The collection dictionary, or nil when the document is no portfolio.
    public static func read(_ document: PdfDocument) -> PdfPortfolio? {
        guard let collection = document.dict(document.catalog, "Collection") else { return nil }
        var fields: [PortfolioField] = []
        if let schema = document.dict(collection, "Schema") {
            for entry in schema.entries.filter({ $0.key != "Type" }).prefix(1000) {
                guard let field = document.resolve(entry.value) as? PdfDictionary else { continue }
                fields.append(PortfolioField(
                    entry.key, PdfText.read(document, field, "N") ?? entry.key, document.name(field, "Subtype") ?? "S",
                    Int(Int32(truncatingIfNeeded: document.integer(field, "O") ?? 0)), document.bool(field, "V") ?? true,
                    document.bool(field, "E") ?? false))
            }
        }
        // OrderBy is stable.
        let ordered = fields.enumerated().sorted { $0.element.order != $1.element.order ? $0.element.order < $1.element.order : $0.offset < $1.offset }
        return PdfPortfolio(document.name(collection, "View") ?? "D", PdfText.read(document, collection, "D"), ordered.map { $0.element })
    }
}
