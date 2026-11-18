#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The tags view of the accessibility panel; follows the tag tree part of windows/LazyPDF.App/Tools/Accessibility/AccessibilityPanel.xaml.
// Lines are dragged onto each other on the Mac and reordered in the list's edit mode on the iPhone and iPad; every command is also
// a VoiceOver action of its line.

struct TagsView: View {
    let model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tagsNote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if let why = model.tagReadOnly {
                Label(why, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasTags { TagTools(model: model) }
        }
    }
}

private struct TagTools: View {
    @Bindable var model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(L10n.t("Filter"))
            TextField(L10n.t("Filter"), text: $model.tagFilter)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.t("Filter"))
            TagCommandButtons(model: model)
            if !model.tagMessage.isEmpty {
                Text(model.tagMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            TagTree(model: model)
            if model.showsEditor { TagEditor(model: model) }
            TagSelectionTools(model: model)
        }
    }
}

private struct TagCommandButtons: View {
    let model: AccessibilityModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(TagCommand.allCases, id: \.self) { command in
                Button(command.text) { model.run(command) }
                    .disabled(!model.canRun(command))
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct TagTree: View {
    let model: AccessibilityModel
    #if os(iOS)
    @State private var editing = EditMode.inactive
    #endif

    var body: some View {
        #if os(iOS)
        VStack(alignment: .trailing, spacing: 4) {
            EditButton()
            list
        }
        .environment(\.editMode, $editing)
        #else
        list
        #endif
    }

    private var list: some View {
        content
        .listStyle(.plain)
        .frame(height: 320)
        .accessibilityLabel(L10n.t("Tag tree"))
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    // On the Mac the list keeps the pick, so the arrow keys move it and the list can take the keyboard.
    @ViewBuilder private var content: some View {
        #if os(macOS)
        List(selection: picked) { rows }
        #else
        List { rows }
        #endif
    }

    private var picked: Binding<String?> {
        Binding(
            get: { model.selectedTag },
            set: { id in
                if let id, id != model.selectedTag, let row = model.tagRows.first(where: { $0.id == id }) { model.select(row) }
            })
    }

    @ViewBuilder private var rows: some View {
        #if os(iOS)
        ForEach(model.tagRows) { row in TagRowView(model: model, row: row) }
            .onMove { source, destination in model.moveRows(from: source, to: destination) }
        #else
        ForEach(model.tagRows) { row in TagRowView(model: model, row: row) }
        #endif
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.selectedTag != nil, let command = Self.command(for: press) else { return .ignored }
        model.run(command)
        return .handled
    }

    private static func command(for press: KeyPress) -> TagCommand? {
        // Arrow keys carry the numeric pad flag and Forward Delete the function flag; neither is a key the user pressed.
        let modifiers = press.modifiers.subtracting([.numericPad, .function])
        if modifiers == .option {
            if press.key == .upArrow { return .moveUp }
            if press.key == .downArrow { return .moveDown }
            if press.key == .rightArrow { return .indent }
            if press.key == .leftArrow { return .outdent }
        }
        if press.key == .delete || press.key == .deleteForward {
            if modifiers.isEmpty { return .delete }
            if modifiers == .control { return .deleteAsArtifact }
        }
        return nil
    }
}

private struct TagRowView: View {
    static let height: CGFloat = 34

    let model: AccessibilityModel
    let row: TagRow

    private var selected: Bool { model.selectedTag == row.id }

    var body: some View {
        HStack(spacing: 4) {
            disclosure
            Button {
                model.select(row)
            } label: {
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(row.isMore)
            .accessibilityLabel(row.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .modifier(TagActions(model: model, row: row))
        .modifier(TagDragging(model: model, row: row))
    }

    @ViewBuilder private var disclosure: some View {
        if row.hasKids {
            Button {
                model.toggle(row)
            } label: {
                Image(systemName: row.isOpen ? "chevron.down" : "chevron.right")
                    .frame(width: 24, height: Self.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isOpen ? L10n.t("Close") : L10n.t("Open"))
        } else {
            Color.clear.frame(width: 24, height: 1)
        }
    }

    @ViewBuilder private var menu: some View {
        ForEach(TagCommand.allCases, id: \.self) { command in
            Button(command.text) { model.run(command, on: row) }
                .disabled(!model.canRun(command, on: row))
        }
    }
}

// The commands as VoiceOver actions, so a node can be moved without dragging it.
private struct TagActions: ViewModifier {
    let model: AccessibilityModel
    let row: TagRow

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text(TagCommand.moveUp.text)) { model.run(.moveUp, on: row) }
            .accessibilityAction(named: Text(TagCommand.moveDown.text)) { model.run(.moveDown, on: row) }
            .accessibilityAction(named: Text(TagCommand.indent.text)) { model.run(.indent, on: row) }
            .accessibilityAction(named: Text(TagCommand.outdent.text)) { model.run(.outdent, on: row) }
            .accessibilityAction(named: Text(TagCommand.delete.text)) { model.run(.delete, on: row) }
            .accessibilityAction(named: Text(TagCommand.deleteAsArtifact.text)) { model.run(.deleteAsArtifact, on: row) }
            .accessibilityAction(named: Text(TagCommand.markAsArtifact.text)) { model.run(.markAsArtifact, on: row) }
            .accessibilityAction(named: Text(TagCommand.makeHeaderRow.text)) { model.run(.makeHeaderRow, on: row) }
    }
}

// A line dropped on the upper quarter of another goes before it, on the lower quarter after it, and in between into it.
private struct TagDragging: ViewModifier {
    let model: AccessibilityModel
    let row: TagRow

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .draggable(row.id)
            .dropDestination(for: String.self) { ids, location in
                guard let id = ids.first else { return false }
                return model.drop(id, onto: row, zone: Self.zone(location.y))
            }
        #else
        content
        #endif
    }

    private static func zone(_ y: CGFloat) -> DropZone {
        if y < TagRowView.height / 4 { return .before }
        return y > TagRowView.height * 3 / 4 ? .after : .into
    }
}

private struct TagEditor: View {
    @Bindable var model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TypeField(title: L10n.t("Type"), text: $model.form.type, types: model.tagTypes)
            field(L10n.t("Title"), $model.form.title)
            field(L10n.t("Alternate text"), $model.form.alt)
            field(L10n.t("Replacement text"), $model.form.actualText)
            field(L10n.t("Language"), $model.form.lang)
            if model.editsCell { cell }
            if !model.formMessage.isEmpty {
                Text(model.formMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button(L10n.t("Apply")) { model.applyForm() }
                .buttonStyle(.bordered)
                .disabled(!model.canApplyForm)
        }
        .disabled(model.tagReadOnly != nil)
    }

    @ViewBuilder private var cell: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(L10n.t("Scope"))
            Picker(L10n.t("Scope"), selection: $model.form.scope) {
                Text(L10n.t("Not set")).tag("")
                Text(L10n.t("Row")).tag("Row")
                Text(L10n.t("Column")).tag("Column")
                Text(L10n.t("Both")).tag("Both")
            }
            .labelsHidden()
        }
        field(L10n.t("Row span"), $model.form.rowSpan)
        field(L10n.t("Column span"), $model.form.colSpan)
        field(L10n.t("Header cells"), $model.form.headers)
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(title)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { model.applyForm() }
                .accessibilityLabel(title)
        }
    }
}

/// A text field for a structure type, with a menu of the types the file can use.
private struct TypeField: View {
    let title: String
    @Binding var text: String
    let types: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldLabel(title)
            HStack {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel(title)
                Menu {
                    ForEach(types, id: \.self) { type in
                        Button(type) { text = type }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(title)
            }
        }
    }
}

private struct TagSelectionTools: View {
    @Bindable var model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TypeField(title: L10n.t("Tag the selection as"), text: $model.tagAs, types: model.tagTypes)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                Button(L10n.t("Tag selection")) { Task { await model.tagSelection() } }
                Button(L10n.t("Tag drawn area")) { model.drawArea() }
                Button(L10n.t("Selection as artifact")) { Task { await model.tagSelectionAsArtifact() } }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.tagReadOnly != nil)
    }
}
#endif
