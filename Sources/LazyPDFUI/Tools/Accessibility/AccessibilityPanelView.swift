#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of AccessibilityModel; follows windows/LazyPDF.App/Tools/Accessibility/AccessibilityPanel.xaml. The four views take
// turns under one segmented control.

struct AccessibilityPanelView: View {
    @Bindable var model: AccessibilityModel

    var body: some View {
        ToolForm {
            if model.isSigned {
                Label(L10n.t("This file is signed. Changes here break the signatures."), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(L10n.t("Accessibility"), selection: Binding(get: { model.view }, set: { model.setView($0) })) {
                Text(L10n.t("Check")).tag(AccessibilityView.check)
                Text(L10n.t("Tags")).tag(AccessibilityView.tags)
                Text(L10n.t("Figures")).tag(AccessibilityView.figures)
                Text(L10n.t("Read")).tag(AccessibilityView.read)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.view {
            case .check: CheckView(model: model)
            case .tags: TagsView(model: model)
            case .figures: FiguresView(model: model)
            case .read: ReadView(model: model)
            }
        }
        .disabled(model.isTagging)
    }
}

private struct CheckView: View {
    let model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.checkSummary)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            ForEach(model.rows) { row in CheckRowView(model: model, row: row) }
        }
    }
}

private struct CheckRowView: View {
    let model: AccessibilityModel
    @Bindable var row: CheckRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.symbol)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).font(.body.weight(.semibold))
                Text(row.status).font(.caption).foregroundStyle(.secondary)
                Text(row.message).fixedSize(horizontal: false, vertical: true)
                if row.hasEditor {
                    TextField(row.editorName, text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                HStack {
                    if row.hasEditor { Button(row.saveText) { model.save(row) } }
                    if row.hasAction { Button(row.actionText) { model.act(row) } }
                    if row.hasPlaces { Button(row.placeText) { model.place(row) } }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.summary)
    }

    private var color: Color {
        switch row.level {
        case .passed: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}

private struct TagsView: View {
    let model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tagsNote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if !model.tagNodes.isEmpty {
                List(model.tagNodes, children: \.children) { node in
                    Button {
                        model.selectNode(node)
                    } label: {
                        Text(node.label).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(node.isMore)
                    .accessibilityLabel(node.label)
                }
                .listStyle(.plain)
                .frame(height: 320)
                .accessibilityLabel(L10n.t("Tag tree"))
            }
        }
    }
}

private struct FiguresView: View {
    @Bindable var model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.figuresNote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if !model.figures.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.figures) { row in
                            Button {
                                model.selectFigure(row.number)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).font(.body.weight(.semibold)).lineLimit(1)
                                    Text(row.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(model.selectedFigure == row.number ? Color.accentColor.opacity(0.2) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(row.automationName)
                            .accessibilityAddTraits(model.selectedFigure == row.number ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 132)
                .accessibilityLabel(L10n.t("Figures"))
            }
            if model.selectedFigure != nil { editor }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                picture.frame(width: 104, height: 120)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(L10n.t("Description"))
                    TextEditor(text: Binding(get: { model.altText }, set: { model.typeAlt($0) }))
                        .frame(minHeight: 96)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                        .accessibilityLabel(L10n.t("Description"))
                }
            }
            HStack {
                Button(L10n.t("Save description")) { model.saveAlt() }.disabled(!model.canSaveAlt)
                Button(L10n.t("Next without one")) { model.nextBare() }.disabled(!model.canFindBare)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = model.figurePicture.flatMap(Self.cgImage) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .padding(4)
                .accessibilityLabel(L10n.t("Picture of the figure"))
        } else if model.figureNoPicture {
            Text(L10n.t("No picture")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        } else {
            Color.clear
        }
    }

    static func cgImage(_ image: PdfRgbaImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.rgba.count >= image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

private struct ReadView: View {
    let model: AccessibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.readNote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            Button {
                model.toggleReading()
            } label: {
                Label(model.isReading ? L10n.t("Stop reading") : L10n.t("Read aloud"), systemImage: model.isReading ? "stop.fill" : "speaker.wave.2")
                    .frame(minHeight: 28)
            }
            .disabled(!model.canRead)
            if !model.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                                Button {
                                    model.selectLine(index)
                                } label: {
                                    Text(line)
                                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                        .background(model.readIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .accessibilityLabel(line)
                                .accessibilityAddTraits(model.readIndex == index ? .isSelected : [])
                            }
                        }
                    }
                    .onChange(of: model.readIndex) { _, index in
                        if let index { proxy.scrollTo(index) }
                    }
                }
                .frame(maxHeight: 320)
                .accessibilityLabel(L10n.t("Reading order"))
            }
        }
    }
}
#endif
