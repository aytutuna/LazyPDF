#if canImport(SwiftUI) && canImport(CoreGraphics)
import CoreGraphics
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of FillSignModel; follows windows/LazyPDF.App/Tools/FillSign/FillSignPanel.xaml.

struct FillSignPanelView: View {
    @Bindable var model: FillSignModel

    var body: some View {
        ToolForm {
            Picker(L10n.t("Fill and sign"), selection: Binding(get: { model.kind }, set: { model.selectKind($0) })) {
                Text(L10n.t("Signature")).tag(FillSignModel.Kind.signature)
                Text(L10n.t("Initials")).tag(FillSignModel.Kind.initials)
                Text(L10n.t("Text")).tag(FillSignModel.Kind.text)
                Text(L10n.t("Date")).tag(FillSignModel.Kind.date)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ReasonText(L10n.t("Choose what to put on the page, then press Place on page."))
            if model.isImage { savedPane } else { textPane }
            if model.placing {
                Label(model.hint, systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .sheet(isPresented: $model.showMaker) {
            ScrollView { SignatureMakerView(model: model) }
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 520)
                #endif
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
    }

    private var savedPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(L10n.t("Saved"))
            if model.saved.isEmpty {
                ReasonText(L10n.t("Nothing is saved yet."))
            } else {
                ForEach(model.saved) { row in
                    HStack(spacing: 8) {
                        Button {
                            model.select(row)
                        } label: {
                            HStack {
                                SignaturePicture(image: row.image)
                                    .frame(height: 40)
                                    .padding(4)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                                Spacer(minLength: 0)
                                if model.selected == row.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.name)
                        .accessibilityAddTraits(model.selected == row.id ? .isSelected : [])
                        Button {
                            model.remove(row)
                        } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("Remove"))
                    }
                }
            }
            Button {
                model.makeNew()
            } label: {
                Label(L10n.t("Make a new one"), systemImage: "plus").frame(minHeight: 44)
            }
        }
    }

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.kind == .text {
                LabelledField(L10n.t("Text")) {
                    TextField(L10n.t("Text"), text: $model.words, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                LabelledField(L10n.t("Format")) {
                    Picker(L10n.t("Date format"), selection: $model.formatIndex) {
                        ForEach(Array(model.dates.enumerated()), id: \.offset) { Text($0.element.sample).tag($0.offset) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LabelledField(L10n.t("Size")) {
                Picker(L10n.t("Size"), selection: $model.size) {
                    ForEach(FillSignModel.sizes, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A picture with see-through parts, shown at its own proportions.
struct SignaturePicture: View {
    let image: PdfRgbaImage

    var body: some View {
        if let cg = SignatureImage.cgImage(image) {
            Image(decorative: cg, scale: 1).resizable().scaledToFit()
        }
    }
}

enum SignatureImage {
    /// The straight (not premultiplied) pixels as a picture; nil when they do not fit the size.
    static func cgImage(_ image: PdfRgbaImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.rgba.count == image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
