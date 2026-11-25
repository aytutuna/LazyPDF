#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of ExportModel; follows windows/LazyPDF.App/Tools/Export/ExportPanel.xaml.

struct ExportPanelView: View {
    let model: ExportModel

    var body: some View {
        @Bindable var model = model
        ToolForm {
            LabelledField(L10n.t("Save as")) {
                Picker(L10n.t("Save as"), selection: $model.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            LabelledField(L10n.t("Pages")) {
                Picker(L10n.t("Pages"), selection: $model.scope) {
                    Text(L10n.t("All pages")).tag(PageScope.all)
                    Text(L10n.t("This page")).tag(PageScope.current)
                    Text(L10n.t("These pages")).tag(PageScope.typed)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                TextField(L10n.t("Type pages like 1-3, 5"), text: $model.pagesText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.scope != .typed)
                    .accessibilityLabel(L10n.t("Pages to export"))
            }
            if let blocker = model.blocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.format == .html {
                LabelledField(L10n.t("Layout")) {
                    Picker(L10n.t("Layout"), selection: $model.fixedHtml) {
                        Text(L10n.t("Text that reflows")).tag(false)
                        Text(L10n.t("Text where it is on the page")).tag(true)
                    }
                    .labelsHidden()
                }
            }
            if model.format == .markdown {
                Toggle(L10n.t("Include pictures"), isOn: $model.markdownPictures)
            }
            if model.format == .pictures { pictureOptions(model) }
        }
    }

    @ViewBuilder
    private func pictureOptions(_ model: ExportModel) -> some View {
        @Bindable var model = model
        LabelledField(L10n.t("Picture type")) {
            Picker(L10n.t("Picture type"), selection: $model.picture) {
                Text("PNG").tag(PictureFormat.png)
                Text("JPEG").tag(PictureFormat.jpeg)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        LabelledField(L10n.t("Resolution")) {
            Picker(L10n.t("Resolution"), selection: $model.dpiIndex) {
                ForEach(Array(ExportModel.dpiSteps.enumerated()), id: \.offset) { Text(L10n.t("{0} dpi", $0.element)).tag($0.offset) }
            }
            .labelsHidden()
        }
        if model.picture == .jpeg {
            LabelledField(L10n.t("Quality")) {
                HStack {
                    Slider(value: Binding(get: { Double(model.quality) }, set: { model.quality = Int($0) }), in: 1...100, step: 1)
                        .accessibilityLabel(L10n.t("Quality"))
                    Text("\(model.quality)").monospacedDigit().frame(width: 32, alignment: .trailing)
                }
            }
        }
    }
}
#endif
