#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of ProtectModel; follows windows/LazyPDF.App/Tools/Protect/ProtectPanel.xaml.

struct ProtectPanelView: View {
    @Bindable var model: ProtectModel
    @State private var storeOpen = false

    var body: some View {
        ToolForm {
            Label(model.stateNote, systemImage: model.stateSymbol)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.asksForUnlock {
                LabelledField(L10n.t("Current permissions password")) {
                    SecureField(L10n.t("Current permissions password"), text: $model.unlockPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !model.lockedForGood {
                modes
                switch model.mode {
                case .remove: ReasonText(L10n.t("The copy opens without a password. The file in view stays as it is."))
                case .password: passwordSection
                case .certificates: recipientSection
                }
                if model.mode != .remove {
                    limitSection
                    encryptionSection
                }
            }
            if !model.warnNote.isEmpty {
                Label(model.warnNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var modes: some View {
        Picker(L10n.t("Protect"), selection: $model.mode) {
            Text(L10n.t("Password")).tag(ProtectMode.password)
                .accessibilityLabel(L10n.t("Protect with a password"))
            Text(L10n.t("Certificates")).tag(ProtectMode.certificates)
                .accessibilityLabel(L10n.t("Protect for certificates"))
            if model.isEncrypted {
                Text(L10n.t("Remove")).tag(ProtectMode.remove)
                    .accessibilityLabel(L10n.t("Remove protection"))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("Password to open")) {
                SecureField(L10n.t("Password to open"), text: $model.openPassword)
                    .textFieldStyle(.roundedBorder)
                ProgressView(value: Double(model.strength.rawValue), total: 4)
                    .tint(strengthColour)
                    .accessibilityLabel(L10n.t("Password strength"))
                    .accessibilityValue(model.strengthHint)
                ReasonText(model.strengthHint)
            }
            LabelledField(L10n.t("Repeat password")) {
                SecureField(L10n.t("Repeat password"), text: $model.repeatPassword)
                    .textFieldStyle(.roundedBorder)
                if !model.passwordNote.isEmpty { ReasonText(model.passwordNote).accessibilityAddTraits(.updatesFrequently) }
            }
        }
    }

    private var strengthColour: Color {
        switch model.strength {
        case .none, .weak: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .strong: return .green
        }
    }

    private var recipientSection: some View {
        LabelledField(L10n.t("People who can open it")) {
            ForEach(model.recipients) { recipient in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.name)
                        ReasonText(recipient.details())
                    }
                    Spacer()
                    Button {
                        model.remove(recipient)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("Remove"))
                }
                .accessibilityElement(children: .combine)
            }
            if !model.recipientNote.isEmpty { ReasonText(model.recipientNote).accessibilityAddTraits(.updatesFrequently) }
            HStack {
                Button(L10n.t("From the keychain")) {
                    model.refreshStore()
                    storeOpen = true
                }
                Button(L10n.t("From a file")) {
                    Task { await model.addFromFiles() }
                }
            }
            .confirmationDialog(L10n.t("Certificates"), isPresented: $storeOpen) {
                ForEach(model.storeChoices) { recipient in
                    Button(recipient.name) { model.add(recipient) }
                }
            } message: {
                Text(model.storeChoices.isEmpty ? L10n.t("No certificates found.") : L10n.t("People who can open it"))
            }
        }
    }

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("Limit what people can do"), isOn: $model.limited)
            if model.limited {
                if model.mode == .password {
                    LabelledField(L10n.t("Permissions password")) {
                        SecureField(L10n.t("Permissions password"), text: $model.ownerPassword)
                            .textFieldStyle(.roundedBorder)
                        if !model.ownerNote.isEmpty { ReasonText(model.ownerNote).accessibilityAddTraits(.updatesFrequently) }
                    }
                }
                FieldLabel(L10n.t("People may"))
                Toggle(L10n.t("Print"), isOn: $model.canPrint)
                Toggle(L10n.t("Print in high quality"), isOn: $model.canPrintSharp)
                    .disabled(!model.canPrint)
                Toggle(L10n.t("Copy text and pictures"), isOn: $model.canCopy)
                Toggle(L10n.t("Change the file"), isOn: $model.canEdit)
                Toggle(L10n.t("Insert, delete and rotate pages"), isOn: $model.canAssemble)
                Toggle(L10n.t("Add comments"), isOn: $model.canComment)
                Toggle(L10n.t("Fill in forms"), isOn: Binding(get: { model.fillForms }, set: { model.canFill = $0 }))
                    .disabled(model.canComment)
                ReasonText(model.limitNote)
            }
        }
    }

    private var encryptionSection: some View {
        LabelledField(L10n.t("Encryption")) {
            Picker(L10n.t("Encryption"), selection: $model.aes128) {
                Text(L10n.t("AES 256-bit")).tag(false)
                Text(L10n.t("AES 128-bit, for older readers")).tag(true)
            }
            .labelsHidden()
            if !model.strengthNote.isEmpty { ReasonText(model.strengthNote).accessibilityAddTraits(.updatesFrequently) }
        }
    }
}
#endif
