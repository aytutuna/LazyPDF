import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Layers/LayersSidePanel.xaml.cs.

/// A layer, or a heading that groups layers, in the tree.
@MainActor
@Observable
public final class LayerRow: Identifiable {
    public let id: Int
    public let name: String
    public let layer: PdfLayer?
    public let children: [LayerRow]?

    /// Whether the box is ticked; the panel follows the view through `follow`.
    public private(set) var isOn: Bool

    init(id: Int, name: String, layer: PdfLayer?, children: [LayerRow]) {
        self.id = id
        self.name = name
        self.layer = layer
        self.children = children.isEmpty ? nil : children
        isOn = layer?.isOn ?? false
    }

    public var canToggle: Bool { layer.map { !$0.locked } ?? false }

    fileprivate func set(_ on: Bool) {
        isOn = on
    }
}

/// The layers of the file, each with a box. Ticking one changes what the viewer draws, not the file.
@MainActor
@Observable
public final class LayersModel: ToolPanelModel {
    public private(set) var roots: [LayerRow] = []
    public private(set) var isEmpty = true

    @ObservationIgnored private var rows: [LayerRow] = []
    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var viewer: DocumentViewer?
    @ObservationIgnored private var rebuild: ObservationWatch?
    @ObservationIgnored private var follow: ObservationWatch?

    public init() {}

    public var action: ToolAction? { nil }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        rebuild = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.build() })
        follow = ObservationWatch(track: { _ = viewer.layers.layers.map { $0.isOn } }, changed: { [weak self] in self?.followView() })
        build()
    }

    public func detach() {
        rebuild?.stop()
        follow?.stop()
        rebuild = nil
        follow = nil
        roots = []
        rows = []
        tab = nil
        viewer = nil
    }

    /// The person ticked or cleared the box of `row`.
    public func toggle(_ row: LayerRow, _ on: Bool) {
        guard let layer = row.layer, row.canToggle, row.isOn != on else { return }
        row.set(on)
        viewer?.setLayerVisible(layer.reference, on)
    }

    private func build() {
        guard let viewer else { return }
        let set = viewer.layers
        rows = []
        roots = set.order.isEmpty ? set.layers.map { makeRow(name: $0.name, layer: $0, nodes: []) } : set.order.map(row)
        isEmpty = set.layers.isEmpty
    }

    private func row(_ node: LayerNode) -> LayerRow {
        makeRow(name: node.layer?.name ?? node.label ?? "", layer: node.layer, nodes: node.children)
    }

    private func makeRow(name: String, layer: PdfLayer?, nodes: [LayerNode]) -> LayerRow {
        let inside = nodes.map(row)
        let made = LayerRow(id: rows.count, name: name, layer: layer, children: inside)
        rows.append(made)
        return made
    }

    // The view changed the layers (a radio group, or the file itself): the boxes follow.
    private func followView() {
        guard let viewer else { return }
        // A rebuild that ran before the viewer read the new file saw the old layers; the viewer's change brings them here.
        if Set(viewer.layers.layers.map { $0.reference.number }) != Set(rows.compactMap { $0.layer?.reference.number }) {
            build()
            return
        }
        let state = Dictionary(viewer.layers.layers.map { ($0.reference.number, $0.isOn) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if let layer = row.layer, let on = state[layer.reference.number] { row.set(on) }
        }
    }
}
