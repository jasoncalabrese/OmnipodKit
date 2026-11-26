//
//  Omnipod5SupportView.swift
//  OmnipodKit
//
//  Shows the Omnipod 5 connectivity status driven by the loaded O5 certificate(s).
//
//  When a certificate is present we show a green "ready" state describing how to
//  pair an O5 pod relative to the currently-configured pod type. When no
//  certificate is present we show a warning and a "Continue" button that runs the
//  same App Attest download flow used by the pairing setup wizard.
//
//  The overflow ("…") menu offers "Load custom certificate" (only when no cert is
//  loaded), "Export certificate" (when one is loaded) and "Delete saved
//  certificate" with a deletable (non compiled-in) cert.
//
//  Export writes a `.o5keypair` file, private key included, after a warning and
//  device-owner authentication. The keychain copy is this-device-only, so an
//  exported file is the only way to move the identity to a new phone.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
import LoopKit
import LoopKitUI


struct Omnipod5SupportView: View {

    let podType: PodType
    let controllerId: UInt32
    let hasActivePod: Bool
    let refreshO5IdsFromCertStore: () -> Void
    let onCertStoreChanged: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.presentationMode) private var presentationMode

    // Resolve the host app name (Trio/Loop) directly from the bundle rather than
    // the appName environment, which isn't injected on the settings nav path.
    private var appName: String { Bundle.main.bundleDisplayName }

    @State private var certLoaded = !O5RegistrationData.isEmpty
    @State private var deletableCert = O5RegistrationData.deletableCert
    @State private var showingFetchSheet = false
    @State private var showingFileImporter = false
    @State private var importError: String?
    @State private var pendingDelete = false
    @State private var pendingDeleteFinalConfirm = false
    @State private var pendingExport = false
    @State private var exportDocument: O5KeypairDocument?
    @State private var exportFilename = ""
    @State private var exportMessage: ExportMessage?

    private struct ExportMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    /// Without a cert the menu offers "Load custom certificate"; with one it offers
    /// "Export certificate". So there is always at least one option.
    private var menuHasOptions: Bool { true }

    /// The certificate in use for this pump manager if there is one, else any loaded one.
    private var exportableCert: O5RegistrationData? {
        O5RegistrationData.get(controllerId) ?? O5RegistrationData.allValues.first
    }

    var body: some View {
        VStack {
            Spacer()

            if certLoaded {
                loadedContent
            } else {
                needsCertContent
            }

            Spacer()

            if certLoaded {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Text(LocalizedString("OK", comment: "Button to dismiss the Omnipod 5 Support screen"))
                        .actionButtonStyle(.primary)
                        .padding()
                }
            } else {
                Button(action: { showingFetchSheet = true }) {
                    Text(LocalizedString("Continue", comment: "Button to start the O5 certificate download"))
                        .actionButtonStyle(.primary)
                        .padding()
                }
            }
        }
        .navigationTitle(LocalizedString("Omnipod 5 Support", comment: "Title for the Omnipod 5 Support screen"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { overflowMenu }
        .sheet(isPresented: $showingFetchSheet) {
            fetchSheet
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.json, .item]) { result in
            handleImport(result)
        }
        .alert(
            LocalizedString("Import Failed", comment: "Title of o5keypair import-failed alert"),
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button(LocalizedString("OK", comment: "OK button for import-failed alert")) {
                importError = nil
            }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            deleteMessage,
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(deleteSavedCertificateString, role: .destructive) {
                pendingDeleteFinalConfirm = true
            }
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
        }
        .alert(
            deleteSavedCertificateString,
            isPresented: $pendingDeleteFinalConfirm
        ) {
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
            Button(LocalizedString("Continue", comment: "Confirm destructive delete action on the final confirmation alert"), role: .destructive) {
                deleteCertificate()
            }
        } message: {
            Text(finalDeleteMessage)
        }
    }

    // The export modifiers live here rather than on the root view: SwiftUI drops one of
    // two file presenters (the importer is on the root) attached to the same view, and
    // export is only offered while a certificate is loaded, when this view is showing.
    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.green)
                // On its own view so it doesn't share a view with the warning alert below.
                .alert(item: $exportMessage) { message in
                    Alert(title: Text(message.title), message: Text(message.text))
                }
            Text(loadedMessage)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .alert(
            LocalizedString("Export Certificate?", comment: "Title of the O5 certificate export warning"),
            isPresented: $pendingExport
        ) {
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
            Button(LocalizedString("Export", comment: "Confirm exporting the O5 certificate")) {
                authenticateThenExport()
            }
        } message: {
            Text(exportWarningMessage)
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .o5keypair,
            defaultFilename: exportFilename
        ) { result in
            handleExportResult(result)
        }
    }

    @ViewBuilder
    private var needsCertContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(guidanceColors.warning)
            Text(needsCertMessage)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    @ToolbarContentBuilder
    private var overflowMenu: some ToolbarContent {
        // The conditional lives inside the ToolbarItem's view builder (valid on
        // iOS 15); a ToolbarContentBuilder `if` would require iOS 16. When there
        // are no options the item renders empty, so no button appears.
        ToolbarItem(placement: .navigationBarTrailing) {
            if menuHasOptions {
                Menu {
                    if !certLoaded {
                        Button {
                            importError = nil
                            showingFileImporter = true
                        } label: {
                            Label(LocalizedString("Load custom certificate", comment: "Menu action to import an o5keypair file"), systemImage: "square.and.arrow.down")
                        }
                    }
                    if certLoaded {
                        Button {
                            pendingExport = true
                        } label: {
                            Label(LocalizedString("Export certificate", comment: "Menu action to export the O5 certificate as an o5keypair file"), systemImage: "square.and.arrow.up")
                        }
                    }
                    if O5RegistrationData.deletableCert != nil {
                        Button(role: .destructive) {
                            pendingDelete = true
                        } label: {
                            Label(deleteSavedCertificateString, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var fetchSheet: some View {
        NavigationView {
            O5KeyFetchView(
                onKeypairReceived: { registrationData in
                    O5RegistrationData.install(registrationData, source: .downloaded)
                    try? O5CertificateKeychain.save(registrationData, source: .downloaded)
                    showingFetchSheet = false
                    certLoaded = true
                    refreshO5IdsFromCertStore()
                    onCertStoreChanged()
                },
                onCancel: {
                    showingFetchSheet = false
                }
            )
            .navigationTitle(LocalizedString("Omnipod 5 Setup", comment: "Title for O5 key fetch view"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString("Cancel", comment: "Cancel button for O5 key fetch")) {
                        showingFetchSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Messages

    private var deleteSavedCertificateString: String {
        if let deletableCert = O5RegistrationData.deletableCert {
            return String(format: LocalizedString("Delete saved certificate %1$@",
                comment: "Title of the final O5 certificate delete confirmation alert (1: certificate number)"),
                          String(format: "0x%08X", deletableCert.controllerId))
        } else {
            return LocalizedString("Delete saved certificate", comment: "Confirm destructive delete action")
        }
    }

    private var loadedMessage: String {
        String(format: LocalizedString("%1$@ is able to connect to Omnipod 5 Pods.",
            comment: "Heading shown when a valid O5 certificate is loaded (1: app name)"), appName)
    }

    private var needsCertMessage: String {
        let warning = String(format: LocalizedString("%1$@ needs to download and store a certificate from the Internet to connect to Omnipod 5 Pods.",
            comment: "Warning shown when no O5 certificate is loaded (1: app name)"), appName)
        let action = LocalizedString("Press Continue to download a certificate now and enable support for Omnipod 5 on your next Pod change.",
            comment: "Instruction to download an O5 certificate")
        return warning + "\n\n" + action
    }

    private var deleteMessage: String {
        let ncerts = O5RegistrationData.allValues.count
        var activeO5PodMessage = ""
        var baseMessage = ""
        if hasActivePod && podType.isO5 {
            activeO5PodMessage = LocalizedString("Your current Omnipod 5 Pod session will not be affected. ",
                comment: "Confirmation message when forgetting a saved O5 certificate while a pod session is active"
            )
        }
        if ncerts == 1 {
            baseMessage = LocalizedString("You will be unable to pair with a new Omnipod 5 Pod until you reconnect to the Internet to download a new certificate.",
                comment: "Confirmation message when a new certificate will need to be downloaded"
            )
        } else if O5RegistrationData.source(for: controllerId) != nil {
            baseMessage = LocalizedString("A new certificate will be used for the next Omnipod 5 Pod pairing.",
                comment: "Confirmation message when a new certificate will be used"
            )
        } else if activeO5PodMessage.isEmpty {
            baseMessage = LocalizedString("This certificate will be permanently deleted.",
                comment: "Confirmation message when forgetting a saved O5 certificate"
            )
        }

        return activeO5PodMessage + baseMessage
    }

    private var finalDeleteMessage: String {
        deleteMessage + "\n\n" + LocalizedString("Deleting the certificate is not needed to switch another pod or pump type. Are you sure you want to continue?",
            comment: "Final confirmation message before deleting a saved O5 certificate")
    }

    private var exportWarningMessage: String {
        LocalizedString("The file contains this phone's Omnipod 5 private key. Anyone who has it can pair Omnipod 5 Pods as this phone.\n\nSave it somewhere private, such as a password manager, and don't share it. Use it only to load this certificate on a new phone.",
            comment: "Warning shown before exporting the O5 certificate")
    }

    private func sourceText(_ source: O5RegistrationSource) -> String {
        switch source {
        case .compiled:   return LocalizedString("Compiled", comment: "O5 cert source: compiled")
        case .imported:   return LocalizedString("Imported", comment: "O5 cert source: imported")
        case .downloaded: return LocalizedString("Downloaded", comment: "O5 cert source: downloaded")
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let registrationData: O5RegistrationData
            do {
                guard let data = try? Data(contentsOf: url) else {
                    throw O5KeypairFileError.malformed
                }
                // Checks that the keys and certificate belong together, so a bad
                // file fails here rather than at the next pairing.
                registrationData = try O5RegistrationData.fromKeypairFile(data)
            } catch {
                importError = error.localizedDescription
                return
            }
            O5RegistrationData.install(registrationData, source: .imported)
            try? O5CertificateKeychain.save(registrationData, source: .imported)
            importError = nil
            certLoaded = true
            refreshO5IdsFromCertStore()
            onCertStoreChanged()
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Export needs the phone's passcode or Face ID / Touch ID, like a bolus, since the
    /// file carries the private key. Without a passcode set, export is refused.
    private func authenticateThenExport() {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            exportMessage = ExportMessage(
                title: LocalizedString("Export Failed", comment: "Title of the O5 certificate export-failed alert"),
                text: LocalizedString("Set a passcode on this phone to export the certificate.", comment: "O5 export refused because the phone has no passcode"))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: LocalizedString("Export the Omnipod 5 certificate", comment: "Reason shown with Face ID / passcode prompt for O5 certificate export")) { success, _ in
            DispatchQueue.main.async {
                if success {
                    prepareExport()
                }
            }
        }
    }

    private func prepareExport() {
        guard let cert = exportableCert else { return }
        do {
            let data = try cert.keypairFileData()
            exportFilename = cert.keypairFilename
            exportDocument = O5KeypairDocument(data: data)
        } catch {
            exportMessage = ExportMessage(
                title: LocalizedString("Export Failed", comment: "Title of the O5 certificate export-failed alert"),
                text: error.localizedDescription)
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        exportDocument = nil
        switch result {
        case .success:
            exportMessage = ExportMessage(
                title: LocalizedString("Certificate Exported", comment: "Title of the O5 certificate exported alert"),
                text: LocalizedString("Keep this file private. To use it on a new phone, choose Load custom certificate on that phone's Omnipod 5 Support screen.",
                    comment: "Message after the O5 certificate is exported"))
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                return
            }
            exportMessage = ExportMessage(
                title: LocalizedString("Export Failed", comment: "Title of the O5 certificate export-failed alert"),
                text: error.localizedDescription)
        }
    }

    private func deleteCertificate() {
        // Remove every deletable (non-compiled-in) certificate so the store is fully reset.
        for cert in O5RegistrationData.allValues where O5RegistrationData.source(for: cert.controllerId) != .compiled {
            try? O5CertificateKeychain.delete(controllerId: cert.controllerId)
            O5RegistrationData.remove(controllerId: cert.controllerId)
        }
        refreshO5IdsFromCertStore() // a no-op if non O5
        certLoaded = !O5RegistrationData.isEmpty
        onCertStoreChanged()
    }
}
