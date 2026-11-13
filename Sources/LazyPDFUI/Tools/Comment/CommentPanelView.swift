#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CommentModel; follows windows/LazyPDF.App/Tools/Comment/CommentPanel.xaml.

struct CommentPanelView: View {
    let model: CommentModel

    private let two = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ToolForm {
            ReasonText(model.hint)
                .accessibilityAddTraits(.updatesFrequently)
            if model.shapeStarted { shapeRow }
            markupSection
            drawSection
            lookSection
            shareSection
        }
    }

    private var markupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(L10n.t("Mark up text"))
            LazyVGrid(columns: two, spacing: 8) {
                markup(L10n.t("Highlight"), L10n.t("Highlight"), L10n.t("Highlight the selected text."), "highlighter", .highlight)
                markup(L10n.t("Underline"), L10n.t("Underline"), L10n.t("Underline the selected text."), "underline", .underline)
                markup(L10n.t("Strike"), L10n.t("Strikethrough"), L10n.t("Strike out the selected text."), "strikethrough", .strikeOut)
                markup(L10n.t("Squiggly"), L10n.t("Squiggly"), L10n.t("Underline the selected text with a wavy line."), "scribble", .squiggly)
            }
            .disabled(!model.canChange)
        }
    }

    private var drawSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(L10n.t("Draw"))
            LazyVGrid(columns: two, spacing: 8) {
                ForEach(model.palette) { item in
                    Button { model.pick(item.tool) } label: {
                        Label(item.text, systemImage: item.symbol)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.tool == item.tool ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(item.text)
                    .accessibilityAddTraits(model.tool == item.tool ? .isSelected : [])
                }
            }
            .disabled(!model.canChange)
            if model.showsStamp { stampRow }
            if let selected = model.selected { selectedRow(selected) }
            if !model.marks.isEmpty { markList }
        }
    }

    // Under the hint, so that it shows at the small detent of the phone's sheet.
    private var shapeRow: some View {
        HStack(spacing: 8) {
            Button { model.finishShape() } label: {
                Label(L10n.t("Finish shape"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFinishShape)
            Button(role: .cancel) { model.cancelShape() } label: {
                Label(L10n.t("Cancel shape"), systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private var markList: some View {
        LabelledField(L10n.t("Marks on this page")) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.marks) { row in
                    Button { model.select(row) } label: {
                        Text(row.spoken)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(row.isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(row.spoken)
                    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(L10n.t("Look"))
            colours
            slider(L10n.t("Width"), L10n.t("{0} pt", number(model.width)), model.width, 0.5...12, 0.5) { model.setWidth($0) }
            slider(L10n.t("Opacity"), L10n.t("{0} %", number(model.opacity)), model.opacity, 10...100, 5) { model.setOpacity($0) }
            fontRow
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(L10n.t("Share"))
            HStack(spacing: 8) {
                Button { Task { await model.importComments() } } label: {
                    Label(L10n.t("Import"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChange)
                .help(L10n.t("Add comments from an FDF or XFDF file."))
                .accessibilityLabel(L10n.t("Import comments"))
                Menu {
                    Button(L10n.t("FDF file")) { Task { await model.exportComments(xfdf: false) } }
                    Button(L10n.t("XFDF file")) { Task { await model.exportComments(xfdf: true) } }
                } label: {
                    Label(L10n.t("Export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canExport)
                .help(L10n.t("Save the comments as an FDF or XFDF file."))
                .accessibilityLabel(L10n.t("Export comments"))
            }
        }
    }

    private func markup(_ title: String, _ name: String, _ help: String, _ symbol: String, _ kind: AnnotationType) -> some View {
        Button { Task { await model.markup(kind) } } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(name)
        .accessibilityHint(help)
    }

    private var stampRow: some View {
        LabelledField(L10n.t("Stamp text")) {
            HStack {
                TextField(L10n.t("Stamp text"), text: Binding(get: { model.stampName }, set: { model.setStampName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .followsTextDirection(model.stampName)
                    .frame(minHeight: 44)
                Menu {
                    ForEach(model.stamps, id: \.self) { label in
                        Button(label) { model.setStampName(label) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(L10n.t("Stamp text"))
            }
        }
    }

    private func selectedRow(_ selected: SelectedMark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(selected.title)
            HStack(spacing: 8) {
                Button { model.editSelectedText() } label: {
                    Label(L10n.t("Edit text"), systemImage: "pencil.line").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!selected.canEditText || !model.canChange)
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label(L10n.t("Delete"), systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChange)
                .help(L10n.t("Delete the selected mark."))
            }
        }
    }

    private var colours: some View {
        LabelledField(L10n.t("Color")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], alignment: .leading, spacing: 0) {
                ForEach(Array(CommentModel.colours.enumerated()), id: \.offset) { item in
                    swatch(item.element.name, item.element.rgb)
                }
            }
        }
        .disabled(!model.canChange)
    }

    private func swatch(_ name: String, _ rgb: [Double]?) -> some View {
        let chosen = model.isChosen(rgb)
        return Button { model.setColor(rgb) } label: {
            ZStack {
                Circle().fill(rgb.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? Color.clear)
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                if rgb == nil { Text("A").font(.caption) }
            }
            .frame(width: 26, height: 26)
            .padding(4)
            .overlay(Circle().strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 2))
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func slider(_ label: String, _ readout: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double,
                        _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                FieldLabel(label)
                Spacer()
                Text(readout).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Slider(value: Binding(get: { value }, set: set), in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue(readout)
                .frame(minHeight: 44)
        }
        .disabled(!model.canChange)
    }

    private var fontRow: some View {
        LabelledField(L10n.t("Font")) {
            Picker(L10n.t("Font"), selection: Binding(get: { model.family }, set: { model.setFamily($0) })) {
                ForEach(CommentModel.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            Stepper(value: Binding(get: { model.fontSize }, set: { model.setFontSize($0) }), in: 4...144, step: 1) {
                Text(L10n.t("Size")) + Text(": ") + Text(number(model.fontSize))
            }
            .accessibilityLabel(L10n.t("Size"))
            .accessibilityValue(number(model.fontSize))
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { model.bold }, set: { model.setBold($0) })) {
                    Text("B").bold().frame(minWidth: 44, minHeight: 44)
                }
                .toggleStyle(.button)
                .accessibilityLabel(L10n.t("Bold"))
                Toggle(isOn: Binding(get: { model.italic }, set: { model.setItalic($0) })) {
                    Text("I").italic().frame(minWidth: 44, minHeight: 44)
                }
                .toggleStyle(.button)
                .accessibilityLabel(L10n.t("Italic"))
            }
        }
        .disabled(!model.canChange)
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
#endif
