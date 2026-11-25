#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The settings of the selected step; follows the editors of windows/LazyPDF.App/Tools/Batch/BatchPanel.xaml and Setting_Changed
// of BatchPanel.Steps.cs. Only the editor of the step's own kind is shown.

struct BatchStepEditor: View {
    let model: BatchModel
    let step: BatchStep

    private func binding<T>(_ path: WritableKeyPath<BatchStep, T>) -> Binding<T> {
        Binding(get: { model.step?[keyPath: path] ?? step[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step.kind {
            case .clean: clean
            case .ocr: language
            case .compress: preset
            case .watermark: watermark
            case .bates: bates
            case .pdfA: level
            case .pdfUa: Toggle(L10n.t("Mark as PDF/UA when the check passes"), isOn: binding(\.markPdfUa))
            }
        }
    }

    private var clean: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("Keep comments"), isOn: binding(\.keepComments))
            Toggle(L10n.t("Keep form data"), isOn: binding(\.keepForms))
            Toggle(L10n.t("Keep links"), isOn: binding(\.keepLinks))
            Toggle(L10n.t("Keep attachments"), isOn: binding(\.keepAttachments))
        }
    }

    private var language: some View {
        LabelledField(L10n.t("Language")) {
            Picker(L10n.t("Language of the text"), selection: binding(\.text)) {
                ForEach(model.languageChoices, id: \.tag) { Text($0.name).tag($0.tag) }
            }
            .labelsHidden()
            ReasonText(model.languageAdvice)
        }
    }

    private var preset: some View {
        LabelledField(L10n.t("Size")) {
            Picker(L10n.t("Size of the file"), selection: binding(\.preset)) {
                ForEach(BatchPreset.allCases, id: \.self) { Text(BatchText.presetName($0)).tag($0) }
            }
            .labelsHidden()
        }
    }

    private var watermark: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("Text")) {
                TextField(L10n.t("Watermark text"), text: binding(\.text)).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top) {
                NumberBox(label: L10n.t("Opacity %"), help: L10n.t("Opacity in percent"), value: step.opacity, set: { model.setOpacity($0) })
                NumberBox(label: L10n.t("Angle"), help: L10n.t("Angle in degrees"), value: step.angle, set: { model.setAngle($0) })
                NumberBox(label: L10n.t("Width %"), help: L10n.t("Width in percent of the page"), value: step.size, set: { model.setSize($0) })
            }
            LabelledField(L10n.t("Position")) {
                Picker(L10n.t("Position of the watermark"), selection: binding(\.anchorIndex)) {
                    ForEach(0...8, id: \.self) { Text(BatchText.anchorName(StampAnchor(rawValue: $0) ?? .center)).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    private var bates: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("Before the number")) {
                TextField(L10n.t("Text before the number"), text: binding(\.text)).textFieldStyle(.roundedBorder)
            }
            LabelledField(L10n.t("After the number")) {
                TextField(L10n.t("Text after the number"), text: binding(\.suffix)).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top) {
                NumberBox(label: L10n.t("Digits"), help: L10n.t("Digits in the number"), value: step.digits, set: { model.setDigits($0) })
                NumberBox(label: L10n.t("Starts at"), help: L10n.t("First number"), value: step.start, set: { model.setStart($0) })
            }
            LabelledField(L10n.t("Place")) {
                Picker(L10n.t("Where the number goes"), selection: binding(\.place)) {
                    ForEach(BatesPlace.allCases, id: \.self) { Text(BatchText.placeName($0)).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    private var level: some View {
        LabelledField(L10n.t("Level")) {
            Picker(L10n.t("PDF/A level"), selection: binding(\.level)) {
                ForEach(BatchLevel.listed, id: \.self) { Text($0.level.name()).tag($0) }
            }
            .labelsHidden()
        }
    }
}

/// A number the person types: a box that holds something that is not a number keeps the setting it had, so the text is its own.
private struct NumberBox: View {
    let label: String
    let help: String
    let value: Int
    let set: (String) -> Void
    @State private var text = ""

    var body: some View {
        LabelledField(label) {
            TextField(help, text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = String(value) }
                .onChange(of: text) { set(text) }
                .onChange(of: value) { if Int(text) != value { text = String(value) } }
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }
}
#endif
