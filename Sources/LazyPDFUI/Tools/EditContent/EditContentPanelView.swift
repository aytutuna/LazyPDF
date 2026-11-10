#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of EditContentModel; follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.xaml. The pointer works on the
// pages; what the pages show only as outlines (an object, a handle, a link) has a row or a button here as well.

struct EditContentPanelView: View {
    @Bindable var model: EditContentModel
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case font, size, spacing, width, link, find, replace
    }

    var body: some View {
        ToolForm {
            modes
            ReasonText(model.hint)
            if let message = model.message {
                Label {
                    Text(message.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: message.caution ? "exclamationmark.triangle" : "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            }
            if model.sections.addPicture {
                Button {
                    Task { await model.addPicture() }
                } label: {
                    Label(L10n.t("Add a picture"), systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.t("Add a picture"))
            }
            if model.sections.text { text }
            if model.sections.image { picture }
            if model.sections.shape { shape }
            if model.sections.opacity { opacity }
            if model.sections.arrange { arrange }
            if model.sections.link { link }
            onThisPage
            replaceAll
        }
        .disabled(model.isReplacing)
        .onAppear {
            #if os(iOS)
            model.useTouch()
            #endif
        }
        // Leaving a field puts what was typed into the page.
        .onChange(of: focus) { old, _ in
            switch old {
            case .size: model.commitSize()
            case .spacing: model.commitSpacing()
            case .width: model.commitWidth()
            default: break
            }
        }
        .onChange(of: model.linkFocus) { _, _ in focus = .link }
    }

    private var modes: some View {
        HStack(spacing: 6) {
            modeButton(.select, L10n.t("Select"), L10n.t("Select objects"))
            modeButton(.textBox, L10n.t("Text box"), L10n.t("Add a text box"))
            modeButton(.link, L10n.t("Link"), L10n.t("Add or change a link"))
        }
    }

    private func modeButton(_ mode: LazyPDFApp.EditMode, _ title: String, _ label: String) -> some View {
        let on = model.isActive && (model.mode == mode || (mode == .select && model.mode == .crop))
        return Button { model.selectMode(mode) } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(on ? Color.accentColor : Color.secondary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Text

    private var text: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L10n.t("Text"))
            LabelledField(L10n.t("Font")) {
                HStack {
                    TextField(L10n.t("Font"), text: $model.fontName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .font)
                        .onSubmit { model.commitFont() }
                    Menu {
                        ForEach(model.fontChoices, id: \.self) { family in
                            Button(family) { model.chooseFont(family) }
                        }
                    } label: {
                        Image(systemName: "textformat").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L10n.t("Font"))
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                LabelledField(L10n.t("Size")) {
                    HStack {
                        TextField(L10n.t("Size in points"), text: $model.sizeText)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .size)
                            .onSubmit { model.commitSize() }
                            .frame(maxWidth: 80)
                        Text(L10n.t("pt")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
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
            LabelledField(L10n.t("Colour")) {
                Swatches { model.chooseTextColor($0) }
            }
            LabelledField(L10n.t("Alignment")) {
                Picker(L10n.t("Alignment"), selection: Binding(get: { model.alignment }, set: { model.setAlignment($0) })) {
                    Text(L10n.t("Left")).tag(LazyPDFKit.TextAlignment.left)
                    Text(L10n.t("Centre")).tag(LazyPDFKit.TextAlignment.center)
                    Text(L10n.t("Right")).tag(LazyPDFKit.TextAlignment.right)
                    Text(L10n.t("Justify")).tag(LazyPDFKit.TextAlignment.justify)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.sections.spacing {
                LabelledField(L10n.t("Line spacing")) {
                    HStack {
                        TextField(L10n.t("Line spacing in points"), text: $model.spacingText)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .spacing)
                            .onSubmit { model.commitSpacing() }
                            .frame(maxWidth: 80)
                        Text(L10n.t("pt")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.sections.paragraph {
                Button { model.reflowParagraph() } label: {
                    Label(L10n.t("Reflow the paragraph"), systemImage: "text.alignleft").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.sections.paragraphEnabled)
                if let reason = model.paragraphReason { ReasonText(reason) }
            }
            if !model.lineRows.isEmpty {
                DisclosureGroup(L10n.t("Lines")) {
                    ForEach(model.lineRows) { row in
                        Button { model.editLine(row) } label: {
                            Text(row.title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityLabel(L10n.t("Edit line: {0}", row.title))
                    }
                }
            }
        }
    }

    // MARK: Pictures and shapes

    private var picture: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Picture"))
            wide(L10n.t("Replace"), L10n.t("Replace the picture")) { Task { await model.replaceImage() } }
            wide(L10n.t("Save as file"), L10n.t("Save the picture as a file")) { Task { await model.extractImage() } }
            wide(L10n.t("Crop"), L10n.t("Crop the picture")) { model.cropImage() }
        }
    }

    private var shape: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L10n.t("Shape"))
            LabelledField(L10n.t("Fill")) {
                Swatches { model.chooseFill($0) }
            }
            LabelledField(L10n.t("Line")) {
                Swatches { model.chooseLine($0) }
            }
            LabelledField(L10n.t("Line width")) {
                HStack {
                    TextField(L10n.t("Line width in points"), text: $model.widthText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .width)
                        .onSubmit { model.commitWidth() }
                        .frame(maxWidth: 80)
                    Text(L10n.t("pt")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var opacity: some View {
        LabelledField(L10n.t("Opacity")) {
            HStack {
                Slider(value: Binding(get: { model.opacity }, set: { model.setOpacity($0) }), in: 0...100, step: 5)
                    .accessibilityLabel(L10n.t("Opacity"))
                    .accessibilityValue(L10n.t("{0}%", Int(model.opacity)))
                Text(L10n.t("{0}%", Int(model.opacity))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var arrange: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Arrange"))
            if model.sections.order {
                pair((L10n.t("To front"), L10n.t("Bring to front"), { model.order(.front) }),
                     (L10n.t("Forward"), L10n.t("Bring forward"), { model.order(.forward) }))
                pair((L10n.t("Backward"), L10n.t("Send backward"), { model.order(.backward) }),
                     (L10n.t("To back"), L10n.t("Send to back"), { model.order(.back) }))
            }
            pair((L10n.t("Turn left"), L10n.t("Turn left 90 degrees"), { model.turn(left: true) }),
                 (L10n.t("Turn right"), L10n.t("Turn right 90 degrees"), { model.turn(left: false) }))
            pair((L10n.t("Flip across"), L10n.t("Flip left to right"), { model.flip(across: true) }),
                 (L10n.t("Flip down"), L10n.t("Flip top to bottom"), { model.flip(across: false) }))
            pair((L10n.t("Smaller"), L10n.t("Make the selection smaller"), { model.scaleSelection(by: 0.9) }),
                 (L10n.t("Larger"), L10n.t("Make the selection larger"), { model.scaleSelection(by: 1.1) }))
            Button(role: .destructive) { model.deleteSelection() } label: {
                Label(L10n.t("Delete"), systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.t("Delete the selection"))
        }
    }

    // MARK: Links

    private var link: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Link"))
            Picker(L10n.t("Link"), selection: $model.linkToPage) {
                Text(L10n.t("Web address")).tag(false).accessibilityLabel(L10n.t("Link to a web address"))
                Text(L10n.t("Page")).tag(true).accessibilityLabel(L10n.t("Link to a page"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(L10n.t("Where the link goes"), text: $model.linkText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focus, equals: .link)
                .onSubmit { if model.canApplyLink { model.applyLink() } }
            if model.sections.removeLink {
                Button(role: .destructive) { model.removeLink() } label: {
                    Label(L10n.t("Remove the link"), systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // Everything the page shows only as an outline, as rows.
    @ViewBuilder
    private var onThisPage: some View {
        if model.mode == .link, !model.linkRows.isEmpty {
            DisclosureGroup(L10n.t("Links on this page")) {
                ForEach(model.linkRows) { row in
                    Button(row.title) { model.selectLink(row) }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        } else if !model.objectRows.isEmpty {
            DisclosureGroup(L10n.t("On this page")) {
                Toggle(L10n.t("Select several"), isOn: $model.selectSeveral)
                    .frame(minHeight: 44)
                ForEach(model.objectRows) { row in
                    let picked = model.selectedRowIds.contains(row.id)
                    Button { model.selectObject(row) } label: {
                        HStack {
                            Text(row.title)
                            Spacer()
                            if picked { Image(systemName: "checkmark") }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Replace all

    private var replaceAll: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Replace in the whole file"))
            LabelledField(L10n.t("Find")) {
                TextField(L10n.t("Text to find"), text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .find)
                    .onSubmit { Task { await model.replaceAll() } }
            }
            LabelledField(L10n.t("Replace with")) {
                TextField(L10n.t("Text to put in its place"), text: $model.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .replace)
                    .onSubmit { Task { await model.replaceAll() } }
            }
            Toggle(L10n.t("Match case"), isOn: $model.matchCase)
            Toggle(L10n.t("Whole words only"), isOn: $model.wholeWord)
            Button { Task { await model.replaceAll() } } label: {
                Text(L10n.t("Replace all")).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canReplaceAll)
        }
        .padding(.top, 8)
    }

    // MARK: Pieces

    private func wide(_ title: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.bordered)
            .accessibilityLabel(label)
    }

    private func pair(_ left: (String, String, () -> Void), _ right: (String, String, () -> Void)) -> some View {
        HStack(spacing: 8) {
            wide(left.0, left.1, left.2)
            wide(right.0, right.1, right.2)
        }
    }
}

/// The colours of the palette as round buttons with their names for VoiceOver.
private struct Swatches: View {
    let picked: (RgbColor) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 2)], alignment: .leading, spacing: 2) {
            ForEach(Palette.colors.indices, id: \.self) { index in
                let entry = Palette.colors[index]
                Button { picked(entry.color) } label: {
                    Circle()
                        .fill(Color(red: Double(entry.color.r) / 255, green: Double(entry.color.g) / 255, blue: Double(entry.color.b) / 255))
                        .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                        .frame(width: 26, height: 26)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.name)
            }
        }
    }
}
#endif
