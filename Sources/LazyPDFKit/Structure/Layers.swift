import Foundation

// Twin of windows/LazyPDF.Core/Structure/Layers.cs: optional content groups (ISO 32000-1 8.11.2) as the default
// configuration shows them, and which of them are off (`LayerVisibility`, which the text layer reads).

/// An optional content group (ISO 32000-1 8.11.2) as the default configuration shows it.
public struct PdfLayer {
    public let reference: PdfReference
    public let name: String
    public let isOn: Bool
    public let locked: Bool
    public let intent: String?
}

/// A row of the layers panel (/Order): a layer, a label over children, or both.
public struct LayerNode {
    public var label: String?
    public var layer: PdfLayer?
    public var children: [LayerNode]
}

/// The layers of a document under its default configuration (/OCProperties /D).
public struct LayerSet {
    public let layers: [PdfLayer]
    public let order: [LayerNode]
    public let radioGroups: [[PdfReference]]

    public init(layers: [PdfLayer], order: [LayerNode], radioGroups: [[PdfReference]] = []) {
        self.layers = layers
        self.order = order
        self.radioGroups = radioGroups
    }
}

public enum PdfLayers {
    private static let maxLayers = 100_000
    private static let maxDepth = 16

    /// The layers in /OCGs order and the tree of /Order (layers missing from it are appended at the top level). State
    /// follows /BaseState, /ON and /OFF; /AS usage rules are not applied. Empty when the file has no layers.
    public static func read(_ document: PdfDocument) -> LayerSet {
        guard let properties = document.dict(document.catalog, "OCProperties") else { return LayerSet(layers: [], order: []) }
        let config = document.dict(properties, "D")
        let baseState = document.name(config, "BaseState") ?? "ON"
        let on = numbers(document, config, "ON")
        let off = numbers(document, config, "OFF")
        let locked = numbers(document, config, "Locked")

        var layers: [PdfLayer] = []
        var byNumber: [Int: PdfLayer] = [:]
        for item in (document.array(properties, "OCGs")?.items ?? []).prefix(maxLayers) {
            guard let reference = item as? PdfReference, byNumber[reference.number] == nil else { continue }
            guard let group = document.resolve(item) as? PdfDictionary else { continue }
            let state = baseState == "OFF" ? on.contains(reference.number) : !off.contains(reference.number)
            let layer = PdfLayer(reference: reference, name: PdfText.read(document, group, "Name") ?? StructureText.unnamedLayer, isOn: state,
                                 locked: locked.contains(reference.number), intent: intent(document, group))
            layers.append(layer)
            byNumber[reference.number] = layer
        }

        var placed = Set<Int>()
        var order: [LayerNode] = []
        var visited = Set<ObjectIdentifier>()
        if let tree = document.array(config, "Order") { order = nodes(document, tree, byNumber, &placed, &visited, 0) }
        for layer in layers where !placed.contains(layer.reference.number) {
            order.append(LayerNode(label: nil, layer: layer, children: []))
        }
        return LayerSet(layers: layers, order: order, radioGroups: radioGroups(document, config, byNumber))
    }

    /// Shows or hides a layer in the default configuration and writes /ON, /OFF and /BaseState anew: base state ON and
    /// the hidden layers listed in /OFF. Turning a layer on turns off the others of its radio button group
    /// (/RBGroups). Returns false for a layer the file does not list.
    @discardableResult
    public static func setVisible(_ document: PdfDocument, _ layer: PdfReference, _ visible: Bool) -> Bool {
        let current = read(document)
        if current.layers.allSatisfy({ $0.reference.number != layer.number }) { return false }
        var off = Set(current.layers.filter { !$0.isOn }.map { $0.reference.number })
        if visible {
            off.remove(layer.number)
            for group in groups(document, layer.number) { off.formUnion(group.filter { $0 != layer.number }) }
        } else {
            off.insert(layer.number)
        }

        guard let properties = document.dict(document.catalog, "OCProperties") else { return false }
        var config = document.dict(properties, "D")
        if config == nil {
            let created = PdfDictionary()
            properties["D"] = created
            config = created
        }
        config?.remove("BaseState")
        config?.remove("ON")
        let hidden: [PdfObject] = current.layers.filter { off.contains($0.reference.number) }.map { $0.reference }
        if hidden.isEmpty {
            config?.remove("OFF")
        } else {
            config?["OFF"] = PdfArray(hidden)
        }
        return true
    }

    private static func nodes(_ document: PdfDocument, _ array: PdfArray, _ layers: [Int: PdfLayer], _ placed: inout Set<Int>, _ visited: inout Set<ObjectIdentifier>, _ depth: Int) -> [LayerNode] {
        var result: [LayerNode] = []
        // An array that lists itself, or that several arrays list, is read once: the tree is the file's, not a count of the ways to walk it.
        if depth > maxDepth || !visited.insert(ObjectIdentifier(array)).inserted { return result }
        var afterRow = false
        for item in array.items.prefix(maxLayers) {
            let resolved = document.resolve(item)
            if let children = resolved as? PdfArray {
                // An array right after a layer or a label is that row's children; otherwise it is a group without a name.
                let inner = nodes(document, children, layers, &placed, &visited, depth + 1)
                if afterRow, !result.isEmpty {
                    result[result.count - 1].children = inner
                } else {
                    result.append(LayerNode(label: nil, layer: nil, children: inner))
                }
                afterRow = false
            } else if let label = resolved as? PdfString {
                result.append(LayerNode(label: PdfText.decode(label.bytes), layer: nil, children: []))
                afterRow = true
            } else if let r = item as? PdfReference, let layer = layers[r.number], placed.insert(r.number).inserted {
                result.append(LayerNode(label: nil, layer: layer, children: []))
                afterRow = true
            } else {
                afterRow = false
            }
        }
        return result
    }

    private static func radioGroups(_ document: PdfDocument, _ config: PdfDictionary?, _ layers: [Int: PdfLayer]) -> [[PdfReference]] {
        var result: [[PdfReference]] = []
        var seen = Set<Int>()
        var budget = maxLayers
        for group in (document.array(config, "RBGroups")?.items ?? []).prefix(maxLayers) {
            if let g = group as? PdfReference, !seen.insert(g.number).inserted { continue }
            guard let members = document.resolve(group) as? PdfArray else { continue }
            budget -= members.items.count
            if budget < 0 { break }
            let known = members.items.compactMap { $0 as? PdfReference }.filter { layers[$0.number] != nil }
            if known.count >= 2 { result.append(known) }
        }
        return result
    }

    private static func numbers(_ document: PdfDocument, _ config: PdfDictionary?, _ key: String) -> Set<Int> {
        Set((document.array(config, key)?.items ?? []).prefix(maxLayers).compactMap { ($0 as? PdfReference)?.number })
    }

    private static func intent(_ document: PdfDocument, _ group: PdfDictionary) -> String? {
        switch document.resolve(group["Intent"]) {
        case let n as PdfName: return n.value
        case let a as PdfArray:
            if let first = a.items.first, let name = document.resolve(first) as? PdfName { return name.value }
            return nil
        default: return nil
        }
    }

    private static func groups(_ document: PdfDocument, _ number: Int) -> [Set<Int>] {
        let config = document.dict(document.dict(document.catalog, "OCProperties"), "D")
        var result: [Set<Int>] = []
        for group in (document.array(config, "RBGroups")?.items ?? []).prefix(maxLayers) {
            guard let members = document.resolve(group) as? PdfArray else { continue }
            let found = Set(members.items.compactMap { ($0 as? PdfReference)?.number })
            if found.contains(number) { result.append(found) }
        }
        return result
    }
}

/// Which optional content is off in the default view: the groups that are, and the membership dictionaries (8.11.2.2)
/// that follow from them.
final class LayerVisibility {
    private let document: PdfDocument
    private var off = Set<ObjectIdentifier>()

    init(_ document: PdfDocument) {
        self.document = document
        for layer in PdfLayers.read(document).layers where !layer.isOn {
            if let group = document.get(layer.reference.number) as? PdfDictionary { off.insert(ObjectIdentifier(group)) }
        }
    }

    var anyOff: Bool { !off.isEmpty }

    // /VE expressions are not evaluated and count as visible.
    func isHidden(_ group: PdfDictionary) -> Bool {
        if off.contains(ObjectIdentifier(group)) { return true }
        if document.name(group, "Type") != "OCMD" || group.containsKey("VE") { return false }
        var members: [PdfDictionary] = []
        switch document.resolve(group["OCGs"]) {
        case let single as PdfDictionary: members = [single]
        case let array as PdfArray: members = array.items.compactMap { document.resolve($0) as? PdfDictionary }
        default: break
        }
        if members.isEmpty { return false }
        let hidden = members.filter { off.contains(ObjectIdentifier($0)) }.count
        switch document.name(group, "P") ?? "AnyOn" {
        case "AllOn": return hidden > 0
        case "AnyOff": return hidden == 0
        case "AllOff": return hidden < members.count
        default: return hidden == members.count
        }
    }
}
