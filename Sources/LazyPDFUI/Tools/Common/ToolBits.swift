#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// What the tool panels share: the frame a panel sits in, the label over a field, the line of explanation under one, a heading,
// and the choice of where a rewritten file goes (windows/LazyPDF.App/Tools/Optimize/OutputChoice.xaml).

/// The padded column every panel is laid out in.
struct ToolForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The caption over a field. The field carries the same words as its accessibility label.
struct FieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A sentence under a field that says why or what.
struct ReasonText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled field: the caption above, the control under it.
struct LabelledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            content()
        }
    }
}

struct OutputChoiceView: View {
    let output: OutputChoice

    var body: some View {
        @Bindable var output = output
        LabelledField(L10n.t("Save as")) {
            Picker(L10n.t("Save as"), selection: $output.replace) {
                Text(L10n.t("New file")).tag(false)
                Text(L10n.t("This file")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!output.canReplace)
            ReasonText(output.note)
            if output.isSigned {
                Label(output.signedNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
