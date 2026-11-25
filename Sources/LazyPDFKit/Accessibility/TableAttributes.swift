import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TableAttributes.cs: the table attributes of a cell (ISO 32000-1 14.8.5.7),
// from its /A dictionary with /O /Table.

public enum TableScope: String {
    case row = "Row"
    case column = "Column"
    case both = "Both"
}

/// The table attributes of a cell. Nil or empty means not set.
public struct TableAttributes: Equatable {
    public var scope: TableScope?
    public var headers: [String]
    public var rowSpan: Int?
    public var colSpan: Int?

    public init(scope: TableScope? = nil, headers: [String] = [], rowSpan: Int? = nil, colSpan: Int? = nil) {
        self.scope = scope
        self.headers = headers
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }
}

extension StructureTree {
    private static let maxSpan = 100_000
    private static let tableKeys = ["Scope", "RowSpan", "ColSpan", "Headers"]

    /// The table attributes of `element`. /A may be one dictionary, an array of them or an array with a revision number after
    /// each; dictionaries of other owners are skipped, a value that is not valid is not set and, when more dictionaries are
    /// for tables, the first that has a value wins.
    public func tableAttributes(_ element: StructElement) -> TableAttributes {
        var found = TableAttributes()
        var haveHeaders = false
        for d in tableDictionaries(element) {
            if found.scope == nil, let name = document.name(d, "Scope") { found.scope = TableScope(rawValue: name) }
            if found.rowSpan == nil { found.rowSpan = span(d, "RowSpan") }
            if found.colSpan == nil { found.colSpan = span(d, "ColSpan") }
            if !haveHeaders, let list = document.array(d, "Headers") {
                let headers = list.items.prefix(Self.maxNodes).compactMap { (document.resolve($0) as? PdfString).map { PdfText.decode($0.bytes) } }
                if !headers.isEmpty {
                    found.headers = headers
                    haveHeaders = true
                }
            }
        }
        return found
    }

    private func span(_ d: PdfDictionary, _ key: String) -> Int? {
        guard let value = document.integer(d, key), value >= 1, value <= Self.maxSpan else { return nil }
        return value
    }

    /// Writes `attributes` into the first /A dictionary of `element` that is for tables, adding one when there is none, and
    /// takes those values out of the later ones; dictionaries of other owners and revision numbers stay as they were. A span of 1 is the default and is not stored.
    /// What /A held that is not a dictionary or an array is dropped.
    public func setTableAttributes(_ element: StructElement, _ attributes: TableAttributes) {
        let current = document.resolve(element.dictionary["A"])
        var items: [PdfObject]
        if let array = current as? PdfArray {
            items = array.items
        } else if current is PdfDictionary, let stored = element.dictionary["A"] {
            items = [stored]
        } else {
            items = []
        }
        let at = items.firstIndex(where: isTable)
        var original: [String: PdfString] = [:]
        for dictionary in tableDictionaries(element) {
            guard let list = document.array(dictionary, "Headers") else { continue }
            for case let string as PdfString in list.items.prefix(Self.maxNodes).map({ document.resolve($0) }) {
                let text = PdfText.decode(string.bytes)
                if original[text] == nil { original[text] = string }
            }
        }

        // Reading takes the first table dictionary that has a value, so a later one must not keep what is cleared or changed here.
        for i in stride(from: items.count - 1, to: (at ?? -1), by: -1) {
            guard isTable(items[i]), let later = document.resolve(items[i]) as? PdfDictionary,
                  Self.tableKeys.contains(where: { later[$0] != nil }) else { continue }
            let rest = PdfDictionary()
            for entry in later.entries where !Self.tableKeys.contains(entry.key) { rest[entry.key] = entry.value }
            if rest.count == 1 {
                items.remove(at: i)
                if i < items.count && items[i] is PdfNumber { items.remove(at: i) }
            } else {
                items[i] = rest
            }
        }

        let table = PdfDictionary()
        if let at, let old = document.resolve(items[at]) as? PdfDictionary {
            for entry in old.entries { table[entry.key] = entry.value }
        }
        table["O"] = PdfName("Table")
        table["Scope"] = attributes.scope.map { PdfName($0.rawValue) }
        table["RowSpan"] = (attributes.rowSpan ?? 0) > 1 ? PdfNumber(attributes.rowSpan!) : nil
        table["ColSpan"] = (attributes.colSpan ?? 0) > 1 ? PdfNumber(attributes.colSpan!) : nil
        table["Headers"] = attributes.headers.isEmpty ? nil : PdfArray(attributes.headers.map { original[$0] ?? PdfText.toObject($0) as PdfObject })

        let empty = table.count == 1
        if let at {
            if empty {
                items.remove(at: at)
                if at < items.count && items[at] is PdfNumber { items.remove(at: at) }
            } else {
                items[at] = table
            }
        } else if !empty {
            items.append(table)
        }

        let result: PdfObject?
        if items.isEmpty {
            result = nil
        } else if current is PdfArray || items.count > 1 {
            result = PdfArray(items)
        } else {
            result = items[0]
        }
        if result?.description == current?.description { return }
        element.dictionary["A"] = result
    }

    private func isTable(_ item: PdfObject) -> Bool {
        guard let d = document.resolve(item) as? PdfDictionary else { return false }
        return document.name(d, "O") == "Table"
    }

    private func tableDictionaries(_ element: StructElement) -> [PdfDictionary] {
        let attributes = document.resolve(element.dictionary["A"])
        if let single = attributes as? PdfDictionary { return isTable(single) ? [single] : [] }
        guard let array = attributes as? PdfArray else { return [] }
        return array.items.prefix(Self.maxNodes).compactMap { item in
            guard let d = document.resolve(item) as? PdfDictionary, isTable(d) else { return nil }
            return d
        }
    }

    /// Makes `headers` the header cells of `cell` (/Headers). A header without an ID gets one that no element has, since
    /// /Headers names IDs.
    public func setHeaders(_ cell: StructElement, _ headers: [StructElement]) {
        var used = Set(elements.compactMap { $0.id }.filter { !$0.isEmpty }.map { OrdinalString($0) })
        var next = 1
        var ids: [String] = []
        for header in headers {
            if header.id?.isEmpty ?? true {
                while !used.insert(OrdinalString("th\(next)")).inserted { next += 1 }
                header.id = "th\(next)"
            }
            ids.append(header.id!)
        }
        var attributes = tableAttributes(cell)
        attributes.headers = ids
        setTableAttributes(cell, attributes)
    }

    /// Turns the cells of a row into header cells with Scope Column: a TD becomes a TH, a cell that is a TH already keeps its
    /// type. Returns how many cells there are; 0 when `row` is not a TR.
    @discardableResult
    public func makeHeaderRow(_ row: StructElement) -> Int {
        if standardType(row.type) != "TR" { return 0 }
        var count = 0
        for cell in row.children {
            let type = standardType(cell.type)
            if type != "TD" && type != "TH" { continue }
            if type == "TD" { cell.type = "TH" }
            var attributes = tableAttributes(cell)
            attributes.scope = .column
            setTableAttributes(cell, attributes)
            count += 1
        }
        return count
    }
}
