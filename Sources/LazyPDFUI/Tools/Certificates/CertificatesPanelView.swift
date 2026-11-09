#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CertificatesModel; follows windows/LazyPDF.App/Tools/Certificates/CertificatesPanel.xaml. On a phone the sheet is
// the tool: the box is drawn on the page above it, which stays live.

struct CertificatesPanelView: View {
    @Bindable var model: CertificatesModel

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("Sign with")) {
                Picker(L10n.t("Sign with"), selection: $model.useKeychain) {
                    Text(L10n.t("Keychain")).tag(true)
                        .accessibilityLabel(L10n.t("Certificate from the keychain"))
                    Text(L10n.t(".p12 file")).tag(false)
                        .accessibilityLabel(L10n.t("Certificate from a .p12 file"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.useKeychain { keychain } else { file }
            placeSection
            LabelledField(L10n.t("Reason")) {
                TextField(L10n.t("Reason"), text: $model.reason)
                    .textFieldStyle(.roundedBorder)
            }
            LabelledField(L10n.t("Place")) {
                TextField(L10n.t("Place"), text: $model.location)
                    .textFieldStyle(.roundedBorder)
            }
            certify
            stamp
            if model.isSigned { existing }
        }
        .disabled(model.working)
    }

    private var keychain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.t("Certificate"), selection: $model.selectedIdentity) {
                ForEach(model.identities) { choice in
                    Text(choice.issuer.isEmpty ? choice.name : "\(choice.name), \(choice.issuer)").tag(Optional(choice.id))
                }
            }
            .labelsHidden()
            if !model.certificateNote.isEmpty {
                Label(model.certificateNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var file: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.chooseFile() }
            } label: {
                Label(L10n.t("Choose a file"), systemImage: "doc.badge.plus")
                    .frame(minHeight: 44)
            }
            if !model.pfxName.isEmpty { ReasonText(model.pfxName) }
            LabelledField(L10n.t("Password")) {
                SecureField(L10n.t("Password of the .p12 file"), text: $model.pfxPassword)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var placeSection: some View {
        LabelledField(L10n.t("Signature on the page")) {
            Picker(L10n.t("Signature on the page"), selection: Binding(get: { model.placeIndex }, set: { model.setPlace($0) })) {
                ForEach(Array(model.places.enumerated()), id: \.offset) { Text($0.element.text).tag($0.offset) }
            }
            .labelsHidden()
            if model.drawsBox {
                Button {
                    model.drawBox()
                } label: {
                    Label(L10n.t("Draw the box"), systemImage: "rectangle.dashed")
                        .frame(minHeight: 44)
                }
                ReasonText(model.boxText).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var certify: some View {
        LabelledField(L10n.t("Certify")) {
            Picker(L10n.t("Certify"), selection: $model.certifyIndex) {
                ForEach(Array(CertificatesModel.certifyChoices.enumerated()), id: \.offset) { Text($0.element.text).tag($0.offset) }
            }
            .labelsHidden()
            .disabled(model.isSigned)
            if model.isSigned { ReasonText(L10n.t("Only the first signature of a file can certify it.")) }
        }
    }

    private var stamp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("Time stamp"), isOn: $model.timestamp)
            if model.timestamp {
                LabelledField(L10n.t("Time stamp server address")) {
                    TextField(L10n.t("Time stamp server address"), text: $model.timestampUrl)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    if !model.urlNote.isEmpty { ReasonText(model.urlNote).accessibilityAddTraits(.updatesFrequently) }
                }
                Toggle(L10n.t("Long term validation"), isOn: $model.longTerm)
                ReasonText(L10n.t("Keeps the proof that the certificate was good. The signature can then be checked after it expires."))
            }
        }
    }

    private var existing: some View {
        LabelledField(L10n.t("Signatures already in the file")) {
            Button {
                Task { await model.addValidation() }
            } label: {
                Label(L10n.t("Add validation data"), systemImage: "checkmark.shield")
                    .frame(minHeight: 44)
            }
            ReasonText(L10n.t("Asks the certificate servers for proof and stores it in the file."))
        }
        .padding(.top, 8)
    }
}
#endif
