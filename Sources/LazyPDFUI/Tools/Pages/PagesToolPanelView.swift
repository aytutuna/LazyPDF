#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of PagesToolModel; follows windows/LazyPDF.App/Tools/Pages/PagesPanel.xaml. The grid on the stage is PagesStageView.

struct PagesToolPanelView: View {
    @Bindable var model: PagesToolModel

    var body: some View {
        ToolForm {
            ReasonText(L10n.t("Choose pages, then use the buttons. A page can also be dragged to a new place or moved from its menu."))
            if model.grid.isSigned { SignedNote(L10n.t("This file is signed. Changing its pages breaks the signatures.")) }
            Button { model.openOrganize() } label: {
                Label(L10n.t("Organize on the stage"), systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel(L10n.t("Organize on the stage"))
            bar
            Text(model.grid.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            PageGridView(grid: model.grid, cellWidth: 108, cellHeight: 160)
                .frame(height: 340)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            insertSection
            cropSection
            resizeSection
            labelSection
        }
        .sourceQuestion(model.asker)
    }

    private var bar: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], alignment: .leading, spacing: 0) {
            BarButton("rotate.left", L10n.t("Rotate left"), off: !model.canEdit) { model.turn(-90) }
            BarButton("rotate.right", L10n.t("Rotate right"), off: !model.canEdit) { model.turn(90) }
            BarButton("plus.square.on.square", L10n.t("Duplicate"), off: !model.canEdit) { Task { await model.duplicate() } }
            BarButton("arrow.up.doc", L10n.t("Extract to a new file"), off: !model.canEdit) { Task { await model.extract() } }
            BarButton("trash", L10n.t("Delete"), off: !model.canEdit) { model.remove() }
            BarButton("arrow.left", L10n.t("Move earlier"), off: !model.canMoveEarlier) { model.earlier() }
            BarButton("arrow.right", L10n.t("Move later"), off: !model.canMoveLater) { model.later() }
            BarButton("checkmark.circle", L10n.t("Select all")) { model.grid.selectAll() }
        }
    }

    private func expanded(_ section: PagesToolModel.Section) -> Binding<Bool> {
        Binding(get: { model.section == section }, set: { model.setExpanded(section, $0) })
    }

    private var insertSection: some View {
        DisclosureGroup(isExpanded: expanded(.insert)) {
            VStack(alignment: .leading, spacing: 12) {
                LabelledField(L10n.t("Where")) {
                    PlacePicker(place: $model.place)
                }
                Button { model.blank() } label: {
                    Label(L10n.t("Blank page"), systemImage: "plus.rectangle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                LabelledField(L10n.t("Pages to take (empty is all)")) {
                    TextField(L10n.t("Pages to take (empty is all)"), text: $model.taken)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                Button { Task { await model.fromFile() } } label: {
                    Label(L10n.t("Pages from a file"), systemImage: "doc.badge.plus").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Button { Task { await model.replace() } } label: {
                    Label(L10n.t("Replace with a file"), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(!model.canEdit)
            }
            .padding(.top, 4)
        } label: {
            SectionHeading(L10n.t("Insert and replace"))
        }
    }

    private var cropSection: some View {
        DisclosureGroup(isExpanded: expanded(.crop)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.t("Draw a box on the page"), isOn: Binding(get: { model.cropDrawing }, set: { model.setDrawing($0) }))
                ReasonText(model.cropHint)
                Toggle(L10n.t("Every page"), isOn: $model.cropAll)
                    .accessibilityLabel(L10n.t("Crop every page"))
                Button { model.removeCrop() } label: {
                    Label(L10n.t("Remove the crop"), systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .padding(.top, 4)
        } label: {
            SectionHeading(L10n.t("Crop"))
        }
    }

    private var resizeSection: some View {
        DisclosureGroup(isExpanded: expanded(.resize)) {
            VStack(alignment: .leading, spacing: 12) {
                LabelledField(L10n.t("Page size")) {
                    Picker(L10n.t("Page size"), selection: $model.paperIndex) {
                        let papers = PaperSize.all
                        ForEach(papers.indices, id: \.self) { Text(papers[$0].name).tag($0) }
                        Text(L10n.t("Custom size")).tag(papers.count)
                    }
                    .labelsHidden()
                }
                if model.showsCustomSize {
                    LabelledField(L10n.t("Width in mm")) {
                        TextField(L10n.t("Width in mm"), text: $model.customWidth).textFieldStyle(.roundedBorder).numberField()
                    }
                    LabelledField(L10n.t("Height in mm")) {
                        TextField(L10n.t("Height in mm"), text: $model.customHeight).textFieldStyle(.roundedBorder).numberField()
                    }
                }
                Toggle(L10n.t("Scale the content"), isOn: $model.scaleContent)
                ReasonText(model.resizeHint)
            }
            .padding(.top, 4)
        } label: {
            SectionHeading(L10n.t("Resize"))
        }
    }

    private var labelSection: some View {
        DisclosureGroup(isExpanded: expanded(.labels)) {
            VStack(alignment: .leading, spacing: 12) {
                LabelledField(L10n.t("Numbering")) {
                    Picker(L10n.t("Numbering"), selection: $model.labelStyleIndex) {
                        Text("1, 2, 3").tag(0)
                        Text("i, ii, iii").tag(1)
                        Text("I, II, III").tag(2)
                        Text("a, b, c").tag(3)
                        Text("A, B, C").tag(4)
                        Text(L10n.t("Prefix only")).tag(5)
                    }
                    .labelsHidden()
                }
                LabelledField(L10n.t("Prefix")) {
                    TextField(L10n.t("Prefix"), text: $model.labelPrefix).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                LabelledField(L10n.t("Start at")) {
                    TextField(L10n.t("Start at"), text: $model.labelStart).textFieldStyle(.roundedBorder).numberField()
                }
                ReasonText(model.labelHint)
                Button { model.removeLabels() } label: {
                    Label(L10n.t("Remove all labels"), systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .padding(.top, 4)
        } label: {
            SectionHeading(L10n.t("Page labels"))
        }
    }
}

/// The four places a new page can go, as the Where box of the panel and of the organize view lists them.
struct PlacePicker: View {
    @Binding var place: InsertPlace

    var body: some View {
        Picker(L10n.t("Where"), selection: $place) {
            Text(L10n.t("After the selection")).tag(InsertPlace.afterSelection)
            Text(L10n.t("Before the selection")).tag(InsertPlace.beforeSelection)
            Text(L10n.t("At the start")).tag(InsertPlace.atStart)
            Text(L10n.t("At the end")).tag(InsertPlace.atEnd)
        }
        .labelsHidden()
    }
}

/// A button of the bar over a grid: a symbol with the room of a finger and a name for VoiceOver.
struct BarButton: View {
    let symbol: String
    let label: String
    let off: Bool
    let action: () -> Void

    init(_ symbol: String, _ label: String, off: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.off = off
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(off)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct SignedNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
