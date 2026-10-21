import SwiftUI
import VisionKit
import AVFoundation
import NocturneKit

struct AddComputerView: View {
    @ObservedObject var model: ClientModel
    @ObservedObject private var connection: WorkspaceConnection
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = false
    @State private var scannedInvitation: String?
    @State private var scannerError: String?
    init(model: ClientModel) { self.model = model; connection = model.server }
    private var pairingUnavailable: Bool { connection.state == .connecting || model.busy }
    private var linkedInvitation: PairingInvitation? { try? PairingInvitation(pairingLink: model.pairingLink) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("Add a host").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("Open Nocturne Server on your Mac, start the server, and choose “Pair a device.” Scan its QR code or copy a pairing link to set up your workspace and screen sharing.")
                        .font(.subheadline).foregroundStyle(MoonStyle.secondary).lineSpacing(4)
                    MoonPanel {
                        HStack(spacing: 16) {
                            Label("Stream", systemImage: "display")
                            Label("Terminal", systemImage: "terminal")
                            Label("Files", systemImage: "folder")
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(MoonStyle.accent)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Scan to pair").font(.headline)
                        Button { Task { await openScanner() } } label: {
                            HStack {
                                if connection.state == .connecting { ProgressView().tint(MoonStyle.ink) }
                                Label(connection.state == .connecting ? "Connecting…" : "Scan QR code", systemImage: "qrcode.viewfinder")
                            }
                        }.buttonStyle(PrimaryButtonStyle())
                            .disabled(!DataScannerViewController.isSupported || pairingUnavailable)
                            .accessibilityIdentifier("scanPairingQR")
                        if !DataScannerViewController.isSupported {
                            Text("This device cannot scan QR codes. Use a pairing link below.").font(.caption).foregroundStyle(MoonStyle.secondary)
                        }
                        if let scannerError { Text(scannerError).font(.caption).foregroundStyle(.orange) }
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button("Open camera settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Pair with a link").font(.headline)
                        Text("On your Mac, choose Copy pairing link. Send it to this device, then paste it here. No camera access is needed.")
                            .font(.subheadline).foregroundStyle(MoonStyle.secondary)
                        TextField("nocturne://pair?…", text: $model.pairingLink, axis: .vertical)
                            .lineLimit(1...3).textFieldStyle(.roundedBorder)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Pairing link").accessibilityIdentifier("pairingLink")
                            .disabled(pairingUnavailable)
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { model.pairingLink = text; model.error = nil }
                        }.disabled(pairingUnavailable).accessibilityIdentifier("pastePairingLink")
                        if let invitation = linkedInvitation {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(invitation.name).font(.subheadline.weight(.semibold))
                                    Text(invitation.host).font(.caption).foregroundStyle(MoonStyle.secondary)
                                }
                            } icon: { Image(systemName: "desktopcomputer") }
                        }
                        Button { Task { await model.pairServer(model.pairingLink) } } label: {
                            HStack {
                                if connection.state == .connecting { ProgressView().tint(MoonStyle.ink) }
                                Label(connection.state == .connecting ? "Connecting…" : "Pair host", systemImage: "link")
                            }
                        }.buttonStyle(PrimaryButtonStyle())
                            .disabled(model.pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingUnavailable)
                            .accessibilityIdentifier("pairWithLink")
                    }
                    if let error = model.error ?? connection.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if !model.pairedServers.servers.isEmpty {
                        Text("Your other hosts stay paired. Manage them in Settings → Paired hosts.").font(.caption).foregroundStyle(MoonStyle.secondary)
                    }
                    Text("Only use an invitation from a Mac you trust. Its QR code and link share one invitation for one device and expire after five minutes. Terminal and file access are controlled on your Mac.").font(.caption).foregroundStyle(MoonStyle.secondary)
                }.padding(24)
            }.background { NocturneBackdrop() }.navigationTitle("Add host").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(MoonStyle.accent)
            .sheet(isPresented: $scanner, onDismiss: pairScannedInvitation) { QRScanner { result in
                scanner = false
                switch result { case .success(let text): scannedInvitation = text; case .failure(let error): scannerError = error.localizedDescription }
            }.ignoresSafeArea() }
    }
    private func openScanner() async {
        scannerError = nil; model.error = nil
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard DataScannerViewController.isAvailable else {
            scannerError = "The camera is unavailable. Paste a pairing link below, or allow camera access in Settings."; return
        }
        scanner = true
    }
    private func pairScannedInvitation() {
        guard let text = scannedInvitation else { return }
        scannedInvitation = nil
        Task { await model.pairServer(text) }
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
