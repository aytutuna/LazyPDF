#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The page grid on the stage; follows windows/LazyPDF.App/Tools/Pages/OrganizeView.xaml. The shortcuts of the buttons are the
// keys of OrganizeView.Press: Delete, Cut, Copy, Paste and Select all, with Escape for Done.

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
                         open: { model.open($0) })
            Divider()
            footer
        }
        .sourceQuestion(model.asker)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Organize pages"))
    }

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Button { model.done() } label: {
                    Label(L10n.t("Done"), systemImage: "checkmark").frame(minHeight: 44)
                }
                .keyboardShortcut(.cancelAction)
                .help(L10n.t("Back to the document (Esc)"))
                .padding(.trailing, 8)
                BarButton("rotate.left", L10n.t("Rotate left"), off: !any) { model.turnSelection(-90) }
                BarButton("rotate.right", L10n.t("Rotate right"), off: !any) { model.turnSelection(90) }
                BarButton("trash", L10n.t("Delete"), off: !any) { model.remove() }
                    .keyboardShortcut(.delete, modifiers: [])
                BarButton("plus.square.on.square", L10n.t("Duplicate"), off: !any) { Task { await model.duplicate() } }
                BarButton("arrow.up.doc", L10n.t("Extract to a new file"), off: !any) { Task { await model.extract() } }
                BarButton("arrow.left", L10n.t("Move earlier"), off: !any) { model.grid.earlier(model.grid.selection) }
                BarButton("arrow.right", L10n.t("Move later"), off: !any) { model.grid.later(model.grid.selection) }
                BarButton("scissors", L10n.t("Cut"), off: !any) { Task { await model.cut() } }
                    .keyboardShortcut("x", modifiers: .command)
                BarButton("doc.on.doc", L10n.t("Copy"), off: !any) { Task { await model.copy() } }
                    .keyboardShortcut("c", modifiers: .command)
                BarButton("doc.on.clipboard", L10n.t("Paste"), off: !model.canPaste) { Task { await model.paste() } }
                    .keyboardShortcut("v", modifiers: .command)
                BarButton("plus.rectangle", L10n.t("Blank page")) { model.blank() }
                BarButton("doc.badge.plus", L10n.t("Pages from a file")) { Task { await model.fromFile() } }
                PlacePicker(place: $model.place)
                    .frame(width: 170)
                    .padding(.leading, 8)
                BarButton("checkmark.circle", L10n.t("Select all")) { model.grid.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
    }

    private var any: Bool { !model.grid.selected.isEmpty }

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
