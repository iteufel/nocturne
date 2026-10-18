import SwiftUI
import VisionKit
import NocturneKit

struct AddComputerView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var scanner = false
    @State private var manual = false
    init(model: ClientModel) { self.model = model; connection = model.server }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("Welcome to\nyour workspace.").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("Open Nocturne Server on your Mac, start the server, and choose “Pair a device.” One connection brings everything together.")
                        .font(.subheadline).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    MoonPanel {
                        HStack(spacing: 16) {
                            Label("Stream", systemImage: "display")
                            Label("Terminal", systemImage: "terminal")
                            Label("Files", systemImage: "folder")
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(MoonStyle.accent)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect to your Mac").font(.headline)
                        SecureField("Paste pairing link", text: $model.invitationText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("pairingLink")
                        NocturneGlassGroup { HStack(spacing: 12) {
                            PasteButton(payloadType: String.self) { values in if let value = values.first { model.invitationText = value } }.buttonBorderShape(.capsule)
                            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                Button { scanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.font(.subheadline).buttonStyle(NocturneGlassButtonStyle())
                            }
                        } }
                        Button { Task { await model.pairServer(model.invitationText) } } label: {
                            HStack { if connection.state == .connecting { ProgressView().tint(MoonStyle.ink) }; Text(connection.state == .connecting ? "Connecting…" : "Connect to Mac"); Image(systemName: "link") }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(model.invitationText.isEmpty || connection.state == .connecting)
                        if let name = model.savedServerName {
                            Button("Reconnect to \(name)") { Task { await model.reconnectServer(); if connection.state == .connected { dismiss() } } }
                                .disabled(connection.state == .connecting)
                        }
                        if let error = connection.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    Text("The pairing link is private. Terminal and file access are controlled on your Mac.").font(.caption).foregroundStyle(MoonStyle.secondary)
                    DisclosureGroup("Connect by address", isExpanded: $manual) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("For a nearby Nocturne server or another compatible streaming host. Enter its PIN in the server’s Devices screen. Use a Nocturne pairing link to also connect terminal and files.")
                                .font(.caption).foregroundStyle(MoonStyle.secondary).lineSpacing(3)
                            TextField("studio.local or 192.168.1.20", text: $address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .padding(16).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("hostAddress").onSubmit { model.add(address: address) }
                            Button { model.add(address: address) } label: { Label("Find computer", systemImage: "magnifyingglass") }
                                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        }.padding(.top, 16)
                    }.font(.subheadline)
                }.padding(24)
            }.background { NocturneBackdrop() }.navigationTitle("Add computer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(MoonStyle.accent)
            .sheet(isPresented: $scanner) { QRScanner { result in
                scanner = false
                switch result { case .success(let text): model.invitationText = text; case .failure(let error): model.error = error.localizedDescription }
            }.ignoresSafeArea() }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let completion: (Result<String, Error>) -> Void
        var finished = false
        init(completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.hasPrefix("nocturne://pair") {
                    finished = true; dataScanner.stopScanning(); completion(.success(value)); return
                }
            }
        }
    }
}
