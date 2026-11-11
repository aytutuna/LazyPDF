#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The page grid on the stage; follows windows/LazyPDF.App/Tools/Pages/OrganizeView.xaml. The keys of OrganizeView.Press (Delete, Cut,
// Copy, Paste and Select all, with Escape for Done) act only while the grid has the focus, so typing in the inspector is not touched.

struct PagesStageView: View {
    let model: PagesToolModel

    var body: some View {
        if let organize = model.organize {
            OrganizeView(model: organize)
        } else {
            Color.clear
        }
    }
}

struct OrganizeView: View {
    @Bindable var model: OrganizeModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if model.grid.isSigned {
                SignedNote(L10n.t("This file is signed. Changing its pages breaks the signatures."))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            PageGridView(grid: model.grid, cellWidth: model.tileSize + 32, cellHeight: model.tileSize * OrganizeModel.boxRatio + 30,
                         onFiles: { files, before in Task { await model.insertFiles(files, at: before) } },
                         open: { model.open($0) }, onKey: { press($0) })
            Divider()
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Organize pages"))
    }

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Button { model.done() } label: {
                    Label(L10n.t("Done"), systemImage: "checkmark").frame(minHeight: 44)
                }
                .help(L10n.t("Back to the document (Esc)"))
                .padding(.trailing, 8)
                BarButton("rotate.left", L10n.t("Rotate left"), off: !any) { model.turnSelection(-90) }
                BarButton("rotate.right", L10n.t("Rotate right"), off: !any) { model.turnSelection(90) }
                BarButton("trash", L10n.t("Delete"), off: !any) { model.remove() }
                BarButton("plus.square.on.square", L10n.t("Duplicate"), off: !any) { Task { await model.duplicate() } }
                BarButton("plus.rectangle", L10n.t("Blank page")) { model.blank() }
                BarButton("doc.badge.plus", L10n.t("Pages from a file")) { Task { await model.fromFile() } }
                PlacePicker(place: $model.place)
                    .frame(width: 170)
                    .padding(.leading, 8)
                Menu {
                    Button(L10n.t("Extract to a new file"), systemImage: "arrow.up.doc") { Task { await model.extract() } }
                        .disabled(!any)
                    Button(L10n.t("Move earlier"), systemImage: "arrow.left") { model.grid.earlier(model.grid.selection) }
                        .disabled(!model.grid.canMove(-1))
                    Button(L10n.t("Move later"), systemImage: "arrow.right") { model.grid.later(model.grid.selection) }
                        .disabled(!model.grid.canMove(1))
                    Button(L10n.t("Cut"), systemImage: "scissors") { Task { await model.cut() } }
                        .disabled(!any)
                    Button(L10n.t("Copy"), systemImage: "doc.on.doc") { Task { await model.copy() } }
                        .disabled(!any)
                    Button(L10n.t("Paste"), systemImage: "doc.on.clipboard") { Task { await model.paste() } }
                        .disabled(!model.canPaste)
                    Button(L10n.t("Select all"), systemImage: "checkmark.circle") { model.grid.selectAll() }
                    Button(L10n.t("Select none"), systemImage: "xmark.circle") { model.grid.selectNone() }
                        .disabled(!any)
                } label: {
                    Label(L10n.t("More"), systemImage: "ellipsis.circle").frame(minHeight: 44)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.leading, 8)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
    }

    private var any: Bool { !model.grid.selected.isEmpty }

    private func press(_ key: KeyPress) -> KeyPress.Result {
        let selection = model.grid.selection
        if any, key.modifiers == .command || key.modifiers == [.command, .shift] {
            let turning = key.modifiers != .command
            switch key.key {
            case .leftArrow:
                if turning { model.grid.turn(selection, -90) } else { model.grid.earlier(selection) }
                return .handled
            case .rightArrow:
                if turning { model.grid.turn(selection, 90) } else { model.grid.later(selection) }
                return .handled
            default: break
            }
        }
        if key.modifiers == .command {
            switch key.characters {
            case "x": Task { await model.cut() }
            case "c": Task { await model.copy() }
            case "v": Task { await model.paste() }
            case "a": model.grid.selectAll()
            case "d" where any: Task { await model.duplicate() }
            default: return .ignored
            }
            return .handled
        }
        guard key.modifiers.isEmpty else { return .ignored }
        switch key.key {
        case .delete, .deleteForward:
            guard any else { return .ignored }
            model.remove()
        case .escape:
            model.done()
        default:
            return .ignored
        }
        return .handled
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.grid.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            Slider(value: Binding(get: { model.tileSize }, set: { model.setTileSize($0) }), in: 72...320, step: 8)
                .frame(maxWidth: 200)
                .accessibilityLabel(L10n.t("Thumbnail size"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif
